defmodule AssistantWeb.Components.AdminIntegrations do
  @moduledoc false

  use Phoenix.Component

  import AssistantWeb.CoreComponents, only: [icon: 1]

  alias Assistant.IntegrationSettings.Registry

  @group_order ~w(ai_providers google_workspace telegram slack discord google_chat hubspot elevenlabs)

  attr :settings, :list, required: true, doc: "Output of IntegrationSettings.list_all/0"
  attr :group_filter, :string, default: nil, doc: "Optional group id to render only one group"

  def admin_integrations(assigns) do
    # Filter out _enabled toggle keys — they are managed via app card toggles, not admin forms
    settings =
      assigns.settings
      |> maybe_filter_group(assigns.group_filter)
      |> Enum.reject(fn s -> Registry.enabled_key?(s.key) end)

    grouped =
      settings
      |> Enum.group_by(& &1.group)

    ordered_groups =
      @group_order
      |> Enum.filter(&Map.has_key?(grouped, &1))
      |> Enum.map(fn group_id ->
        keys = grouped[group_id]
        label = group_label(group_id)
        {group_id, label, keys}
      end)

    assigns =
      assigns
      |> assign(:ordered_groups, ordered_groups)
      |> assign(:single_group_view, is_binary(assigns.group_filter))

    ~H"""
    <div class="space-y-6">
      <div :for={{group_id, label, keys} <- @ordered_groups} class="rounded-lg border border-zinc-200 bg-white p-4 space-y-4">
        <h3 :if={!@single_group_view} class="font-semibold text-lg">{label}</h3>

        <div class="space-y-4">
          <.setting_row :for={setting <- keys} setting={setting} group_id={group_id} />
        </div>
      </div>

      <div :if={@ordered_groups == []} class="rounded-lg border border-zinc-200 bg-white p-4">
        <p class="text-sm text-zinc-500">No integration settings defined.</p>
      </div>
    </div>
    """
  end

  attr :setting, :map, required: true
  attr :group_id, :string, required: true

  defp setting_row(assigns) do
    key_str = Atom.to_string(assigns.setting.key)
    input_id = "integration-#{key_str}"
    input_type = if assigns.setting.is_secret, do: "password", else: "text"
    use_textarea = String.ends_with?(key_str, "_json")

    assigns =
      assigns
      |> assign(:key_str, key_str)
      |> assign(:input_id, input_id)
      |> assign(:input_type, input_type)
      |> assign(:use_textarea, use_textarea)

    ~H"""
    <div class="rounded-md border border-zinc-100 bg-zinc-50/50 p-3 space-y-2">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <label for={@input_id} class="block text-sm font-medium text-zinc-800">
            {@setting.label}
          </label>
          <p class="text-xs text-zinc-500 mt-0.5">{@setting.help}</p>
        </div>
        <.source_badge source={@setting.source} />
      </div>

      <form
        phx-submit="save_integration"
        id={"form-#{@key_str}"}
        class={if @use_textarea, do: "space-y-2", else: "flex items-center gap-2"}
      >
        <input type="hidden" name="key" value={@key_str} />
        <textarea
          :if={@use_textarea}
          id={@input_id}
          name="value"
          rows="6"
          placeholder={placeholder_for(@setting)}
          autocomplete="off"
          class="w-full rounded-md border border-zinc-300 px-3 py-1.5 text-sm font-mono resize-y"
        />
        <input
          :if={!@use_textarea}
          type={@input_type}
          id={@input_id}
          name="value"
          placeholder={placeholder_for(@setting)}
          autocomplete="off"
          class="flex-1 rounded-md border border-zinc-300 px-3 py-1.5 text-sm font-mono min-w-0"
        />
        <div class={if @use_textarea, do: "flex items-center gap-2", else: "contents"}>
          <button
            type="submit"
            class="shrink-0 rounded-md bg-zinc-800 px-3 py-1.5 text-sm font-medium text-white hover:bg-zinc-700"
          >
            Save
          </button>
          <button
            :if={@setting.source == :db}
            type="button"
            phx-click="delete_integration"
            phx-value-key={@key_str}
            class="shrink-0 rounded-md border border-zinc-300 px-3 py-1.5 text-sm text-zinc-600 hover:bg-zinc-100"
            title="Revert to environment variable"
          >
            <.icon name="hero-arrow-uturn-left" class="h-4 w-4" />
          </button>
        </div>
      </form>

      <p :if={@setting.source != :none} class="text-xs text-zinc-400 font-mono truncate">
        Current: {@setting.masked_value}
      </p>
    </div>
    """
  end

  attr :source, :atom, required: true

  defp source_badge(%{source: :db} = assigns) do
    ~H"""
    <span class="inline-flex items-center rounded-full bg-green-100 px-2 py-0.5 text-xs font-medium text-green-700">
      Database
    </span>
    """
  end

  defp source_badge(%{source: :env} = assigns) do
    ~H"""
    <span class="inline-flex items-center rounded-full bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-700">
      Environment
    </span>
    """
  end

  defp source_badge(%{source: :none} = assigns) do
    ~H"""
    <span class="inline-flex items-center rounded-full bg-zinc-100 px-2 py-0.5 text-xs font-medium text-zinc-500">
      Not Set
    </span>
    """
  end

  defp placeholder_for(%{is_secret: true, source: :none}), do: "Enter secret value..."
  defp placeholder_for(%{is_secret: true}), do: "Enter new value to replace..."
  defp placeholder_for(%{source: :none}), do: "Enter value..."
  defp placeholder_for(_), do: "Enter new value to replace..."

  defp maybe_filter_group(settings, nil), do: settings
  defp maybe_filter_group(settings, group), do: Enum.filter(settings, &(&1.group == group))

  defp group_label("ai_providers"), do: "AI Providers"
  defp group_label("google_workspace"), do: "Google Workspace"
  defp group_label("telegram"), do: "Telegram"
  defp group_label("slack"), do: "Slack"
  defp group_label("discord"), do: "Discord"
  defp group_label("google_chat"), do: "Google Chat"
  defp group_label("hubspot"), do: "HubSpot"
  defp group_label("elevenlabs"), do: "ElevenLabs"
  defp group_label(id), do: id
end
