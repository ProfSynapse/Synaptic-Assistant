defmodule AssistantWeb.SettingsLive do
  use AssistantWeb, :live_view

  alias AssistantWeb.SettingsLive.Events
  alias AssistantWeb.SettingsLive.State

  import AssistantWeb.Components.SettingsPage, only: [settings_page: 1]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, State.init(socket)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, State.handle_params(socket, params)}
  end

  @impl true
  def handle_event(event, params, socket) do
    Events.handle_event(event, params, socket)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.settings_page {assigns} />
    </Layouts.app>
    """
  end
end
