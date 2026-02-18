# lib/assistant/notifications/router.ex — Notification routing GenServer.
#
# Central notification dispatch: receives alerts via `notify/4`, deduplicates
# them, matches against configured rules, and dispatches to appropriate
# channels (Google Chat webhooks, etc.). Runs as a supervised singleton in
# the application supervision tree.

defmodule Assistant.Notifications.Router do
  @moduledoc """
  GenServer that routes notifications to configured channels.

  ## Public API

      Router.notify(:error, "orchestrator", "LLM call failed after 3 retries")

  Notifications are fire-and-forget (`cast`). The router:
  1. Checks dedup — skips if the same component + message was sent recently
  2. Matches against notification rules (severity threshold + component filter)
  3. Dispatches to matching channels (Google Chat webhook, etc.)

  ## Fallback Behavior

  If no rules are configured in the database, the router falls back to the
  `:google_chat_webhook_url` application env, sending `:error` and `:critical`
  alerts there.
  """

  use GenServer

  alias Assistant.Notifications.{Dedup, GoogleChat}

  require Logger

  @severity_levels %{
    info: 0,
    warning: 1,
    error: 2,
    critical: 3
  }

  @sweep_interval_ms 60_000

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Sends a notification (fire-and-forget).

  ## Parameters
    - `severity` — `:info | :warning | :error | :critical`
    - `component` — string identifying the source (e.g., "orchestrator", "llm_client")
    - `message` — human-readable alert text
    - `metadata` — optional map of additional context
  """
  @spec notify(:info | :warning | :error | :critical, String.t(), String.t(), map()) :: :ok
  def notify(severity, component, message, metadata \\ %{}) do
    GenServer.cast(__MODULE__, {:notify, severity, component, message, metadata})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    Dedup.init()
    rules = load_rules()
    sweep_ref = schedule_sweep()

    Logger.info("Notifications.Router started",
      rule_count: length(rules),
      fallback: rules == []
    )

    {:ok, %{rules: rules, dedup_sweep_ref: sweep_ref}}
  end

  @impl true
  def handle_cast({:notify, severity, component, message, metadata}, state) do
    if Dedup.duplicate?(component, message) do
      Logger.debug("Notification deduplicated",
        component: component,
        severity: severity
      )

      {:noreply, state}
    else
      Dedup.record(component, message)
      dispatch(severity, component, message, metadata, state.rules)
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:sweep_dedup, state) do
    removed = Dedup.sweep()

    if removed > 0 do
      Logger.debug("Dedup sweep removed entries", count: removed)
    end

    sweep_ref = schedule_sweep()
    {:noreply, %{state | dedup_sweep_ref: sweep_ref}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private Helpers ---

  # Loads notification rules from the database. On failure (e.g., DB not
  # available in test), returns an empty list which triggers fallback behavior.
  defp load_rules do
    import Ecto.Query

    query =
      from r in Assistant.Schemas.NotificationRule,
        join: c in assoc(r, :channel),
        where: r.enabled == true and c.enabled == true,
        preload: [channel: c]

    case Assistant.Repo.all(query) do
      rules when is_list(rules) ->
        rules

      _ ->
        []
    end
  rescue
    _ -> []
  end

  # Dispatches to matching rules, or falls back to env var webhook.
  defp dispatch(severity, component, message, metadata, rules) do
    formatted = format_message(severity, component, message, metadata)

    case match_rules(severity, component, rules) do
      [] ->
        dispatch_fallback(severity, formatted)

      matched ->
        Enum.each(matched, fn rule ->
          dispatch_to_channel(rule.channel, formatted)
        end)
    end
  end

  # Matches rules by severity threshold and optional component filter.
  defp match_rules(severity, component, rules) do
    severity_level = Map.get(@severity_levels, severity, 0)

    Enum.filter(rules, fn rule ->
      rule_level = Map.get(@severity_levels, String.to_existing_atom(rule.severity_min), 0)
      severity_match = severity_level >= rule_level

      component_match =
        is_nil(rule.component_filter) or
          rule.component_filter == "" or
          rule.component_filter == component

      severity_match and component_match
    end)
  end

  # Routes to a channel based on its type.
  defp dispatch_to_channel(%{type: "google_chat_webhook", config: config}, message) do
    webhook_url = decode_config(config)

    case GoogleChat.send(webhook_url, message) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to dispatch to Google Chat channel",
          error: inspect(reason)
        )
    end
  end

  defp dispatch_to_channel(%{type: type}, _message) do
    Logger.warning("Unsupported notification channel type", type: type)
  end

  # Falls back to the application env webhook for :error and :critical.
  defp dispatch_fallback(severity, message) when severity in [:error, :critical] do
    case Application.get_env(:assistant, :google_chat_webhook_url) do
      nil ->
        Logger.debug("No fallback webhook configured, notification dropped",
          severity: severity
        )

      url when is_binary(url) ->
        case GoogleChat.send(url, message) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to send fallback notification",
              error: inspect(reason)
            )
        end
    end
  end

  defp dispatch_fallback(_severity, _message), do: :ok

  # Formats a notification into a human-readable text message.
  defp format_message(severity, component, message, metadata) do
    severity_tag = severity |> to_string() |> String.upcase()
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    base = "[#{severity_tag}] #{component}: #{message}\nTime: #{timestamp}"

    if map_size(metadata) > 0 do
      meta_str =
        metadata
        |> Enum.map(fn {k, v} -> "  #{k}: #{inspect(v)}" end)
        |> Enum.join("\n")

      "#{base}\nContext:\n#{meta_str}"
    else
      base
    end
  end

  # Decodes channel config (stored as binary). Currently treats it as
  # a plain URL string. Will support JSON-encoded config maps in the future.
  defp decode_config(config) when is_binary(config), do: config

  defp schedule_sweep do
    Process.send_after(self(), :sweep_dedup, @sweep_interval_ms)
  end
end
