defmodule AssistantWeb.Components.ConnectorCard do
  @moduledoc false

  use Phoenix.Component

  import AssistantWeb.CoreComponents, only: [icon: 1]

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :icon_path, :string, required: true
  attr :connected, :boolean, required: true
  attr :on_connect, :string, required: true
  attr :on_disconnect, :string, required: true
  attr :disconnect_confirm, :string, default: "Are you sure you want to disconnect?"
  attr :disabled, :boolean, default: false

  def connector_card(assigns) do
    ~H"""
    <article class="sa-card">
      <div class="sa-row">
        <div class="sa-app-title" style="margin-bottom: 0; flex: 1;">
          <img src={@icon_path} alt={@name} class="sa-app-icon" />
          <h3>{@name}</h3>
        </div>
        
        <div style="display: flex; align-items: center; gap: 1rem;">
          <.icon :if={@connected} name="hero-check-circle" class="h-6 w-6 text-green-500" />
          <.icon :if={!@connected} name="hero-x-circle" class="h-6 w-6 text-red-500" />
          
          <label class="sa-switch">
            <input
              type="checkbox"
              checked={@connected}
              class="sa-switch-input"
              role="switch"
              aria-checked={to_string(@connected)}
              aria-label={"Toggle #{@name}"}
              disabled={@disabled or @on_connect == ""}
              phx-click={if @connected, do: @on_disconnect, else: @on_connect}
              data-confirm={if @connected, do: @disconnect_confirm, else: nil}
            />
            <span class="sa-switch-slider"></span>
          </label>
        </div>
      </div>
      
      <div :if={!@connected}>
        <button :if={@on_connect != ""} type="button" class="sa-btn" style="width: 100%; justify-content: center;" phx-click={@on_connect} disabled={@disabled}>
          Connect
        </button>
        <button :if={@on_connect == ""} type="button" class="sa-btn" style="width: 100%; justify-content: center;" disabled>
          Connect
        </button>
      </div>
      <div :if={@connected}>
        <button type="button" class="sa-btn secondary" style="width: 100%; justify-content: center;" phx-click={@on_disconnect} data-confirm={@disconnect_confirm}>
          Disconnect
        </button>
      </div>
    </article>
    """
  end
end
