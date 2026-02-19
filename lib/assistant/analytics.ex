defmodule Assistant.Analytics do
  @moduledoc """
  Lightweight file-backed analytics store for settings dashboards.

  Events are appended as JSON lines so we can ship analytics UI without
  database migrations. This can be replaced with Ecto persistence later.
  """

  require Logger

  @type event :: map()

  @default_events_path "tmp/analytics/events.jsonl"

  @spec record_llm_call(map()) :: :ok
  def record_llm_call(attrs) when is_map(attrs) do
    event =
      %{
        event_type: "llm_call",
        status: normalize_status(Map.get(attrs, :status) || Map.get(attrs, "status") || :ok),
        scope: Map.get(attrs, :scope) || Map.get(attrs, "scope") || "orchestrator",
        model: Map.get(attrs, :model) || Map.get(attrs, "model"),
        conversation_id: Map.get(attrs, :conversation_id) || Map.get(attrs, "conversation_id"),
        user_id: Map.get(attrs, :user_id) || Map.get(attrs, "user_id"),
        prompt_tokens: int_value(attrs, :prompt_tokens),
        completion_tokens: int_value(attrs, :completion_tokens),
        total_tokens: int_value(attrs, :total_tokens),
        cost: float_value(attrs, :cost),
        duration_ms: int_value(attrs, :duration_ms),
        metadata: Map.get(attrs, :metadata) || Map.get(attrs, "metadata") || %{},
        occurred_at: now_iso8601()
      }

    write_event(event)
  end

  @spec record_tool_call(map()) :: :ok
  def record_tool_call(attrs) when is_map(attrs) do
    event =
      %{
        event_type: "tool_call",
        status: normalize_status(Map.get(attrs, :status) || Map.get(attrs, "status") || :ok),
        scope: Map.get(attrs, :scope) || Map.get(attrs, "scope") || "skill_executor",
        tool_name: Map.get(attrs, :tool_name) || Map.get(attrs, "tool_name"),
        conversation_id: Map.get(attrs, :conversation_id) || Map.get(attrs, "conversation_id"),
        user_id: Map.get(attrs, :user_id) || Map.get(attrs, "user_id"),
        duration_ms: int_value(attrs, :duration_ms),
        metadata: Map.get(attrs, :metadata) || Map.get(attrs, "metadata") || %{},
        occurred_at: now_iso8601()
      }

    write_event(event)
  end

  @spec dashboard_snapshot(keyword()) :: map()
  def dashboard_snapshot(opts \\ []) do
    window_days = Keyword.get(opts, :window_days, 7)
    top_limit = Keyword.get(opts, :top_limit, 5)
    failures_limit = Keyword.get(opts, :failures_limit, 8)

    events = read_recent_events(window_days)

    llm_events = Enum.filter(events, &(&1["event_type"] == "llm_call"))
    tool_events = Enum.filter(events, &(&1["event_type"] == "tool_call"))
    failures = Enum.filter(events, &failure_status?(&1["status"]))

    total_cost =
      llm_events
      |> Enum.reduce(0.0, fn event, acc -> acc + (event["cost"] || 0.0) end)
      |> Float.round(6)

    prompt_tokens = sum_field(llm_events, "prompt_tokens")
    completion_tokens = sum_field(llm_events, "completion_tokens")
    total_tokens = sum_field(llm_events, "total_tokens")
    tool_hits = length(tool_events)
    llm_calls = length(llm_events)

    failure_rate =
      case llm_calls + tool_hits do
        0 -> 0.0
        total -> Float.round(length(failures) * 100.0 / total, 2)
      end

    top_tools =
      tool_events
      |> Enum.group_by(&(&1["tool_name"] || "Unknown Tool"))
      |> Enum.map(fn {tool_name, grouped} -> %{tool_name: tool_name, count: length(grouped)} end)
      |> Enum.sort_by(& &1.count, :desc)
      |> Enum.take(top_limit)

    recent_failures =
      failures
      |> Enum.sort_by(&(&1["occurred_at"] || ""), :desc)
      |> Enum.take(failures_limit)
      |> Enum.map(fn event ->
        %{
          event_type: event["event_type"],
          target: event["tool_name"] || event["model"] || "unknown",
          status: event["status"],
          occurred_at: event["occurred_at"],
          conversation_id: event["conversation_id"]
        }
      end)

    %{
      window_days: window_days,
      total_cost: total_cost,
      prompt_tokens: prompt_tokens,
      completion_tokens: completion_tokens,
      total_tokens: total_tokens,
      tool_hits: tool_hits,
      llm_calls: llm_calls,
      failures: length(failures),
      failure_rate: failure_rate,
      top_tools: top_tools,
      recent_failures: recent_failures
    }
  end

  @spec read_recent_events(pos_integer()) :: [event()]
  def read_recent_events(window_days) when is_integer(window_days) and window_days > 0 do
    since = DateTime.add(DateTime.utc_now(), -window_days * 86_400, :second)

    events_path()
    |> read_events_from_file()
    |> Enum.filter(fn event ->
      with occurred_at when is_binary(occurred_at) <- event["occurred_at"],
           {:ok, dt, _offset} <- DateTime.from_iso8601(occurred_at) do
        DateTime.compare(dt, since) in [:eq, :gt]
      else
        _ -> false
      end
    end)
  end

  def read_recent_events(_), do: []

  defp write_event(event) do
    path = events_path()
    File.mkdir_p!(Path.dirname(path))
    line = Jason.encode!(event) <> "\n"

    case File.write(path, line, [:append]) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to write analytics event", reason: inspect(reason))
        :ok
    end
  rescue
    exception ->
      Logger.warning("Failed to persist analytics event", reason: Exception.message(exception))
      :ok
  end

  defp read_events_from_file(path) do
    if File.exists?(path) do
      path
      |> File.stream!([], :line)
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Stream.map(&Jason.decode/1)
      |> Stream.filter(&match?({:ok, _}, &1))
      |> Stream.map(fn {:ok, event} -> event end)
      |> Enum.to_list()
    else
      []
    end
  rescue
    exception ->
      Logger.warning("Failed to read analytics events", reason: Exception.message(exception))
      []
  end

  defp events_path do
    Application.get_env(:assistant, :analytics_events_path, @default_events_path)
  end

  defp sum_field(events, key) do
    Enum.reduce(events, 0, fn event, acc -> acc + (event[key] || 0) end)
  end

  defp int_value(attrs, key) do
    value = Map.get(attrs, key) || Map.get(attrs, to_string(key))

    case value do
      value when is_integer(value) -> value
      value when is_float(value) -> trunc(value)
      value when is_binary(value) -> parse_integer(value, 0)
      _ -> 0
    end
  end

  defp float_value(attrs, key) do
    value = Map.get(attrs, key) || Map.get(attrs, to_string(key))

    case value do
      value when is_integer(value) -> value / 1
      value when is_float(value) -> value
      value when is_binary(value) -> parse_float(value, 0.0)
      _ -> 0.0
    end
  end

  defp parse_integer(value, default) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      :error -> default
    end
  end

  defp parse_float(value, default) do
    case Float.parse(value) do
      {parsed, _} -> parsed
      :error -> default
    end
  end

  defp normalize_status(value) when value in [:ok, "ok", :success, "success"], do: "ok"
  defp normalize_status(value) when value in [:timeout, "timeout"], do: "timeout"
  defp normalize_status(value) when value in [:crash, "crash"], do: "crash"
  defp normalize_status(value) when value in [:error, "error", :failed, "failed"], do: "error"
  defp normalize_status(value) when is_binary(value), do: String.downcase(value)
  defp normalize_status(value), do: to_string(value)

  defp failure_status?(status), do: status not in ["ok", "success"]

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
