defmodule AssistantWeb.Components.SettingsPage.Models do
  @moduledoc false

  use AssistantWeb, :html

  alias Phoenix.LiveView.JS

  import AssistantWeb.Components.ConnectorCard, only: [connector_card: 1]

  def models_section(assigns) do
    ~H"""
    <div>
      <div class="sa-card">
        <div class="sa-row">
          <h2>OpenRouter</h2>
        </div>
        <p class="sa-muted">Connect your OpenRouter account to use your personal API key for model access.</p>
        <div class="sa-card-grid">
          <.connector_card
            id="openrouter"
            name="OpenRouter"
            icon_path="/images/apps/openrouter.svg"
            connected={@openrouter_connected}
            on_connect="connect_openrouter"
            on_disconnect="disconnect_openrouter"
            disconnect_confirm="Disconnect OpenRouter? The assistant will use the system-level API key instead."
          />
        </div>
      </div>

      <div class="sa-card">
        <h2>Role Defaults</h2>
        <p class="sa-muted">Choose the default model used for each system role.</p>

        <.form
          for={@model_defaults_form}
          id="model-defaults-form"
          phx-submit="save_model_defaults"
          class="sa-model-defaults-form"
        >
          <div class="sa-model-defaults-grid">
            <div :for={role <- @model_default_roles} class="sa-model-default-row">
              <div class="sa-model-default-meta">
                <div class="sa-model-default-title">
                  <span class="sa-model-default-role">{role.label}</span>
                  <button
                    type="button"
                    class="sa-role-tooltip"
                    aria-label={"About #{role.label}"}
                    title={role.tooltip}
                  >
                    <.icon name="hero-information-circle" class="h-4 w-4" />
                    <span class="sa-role-tooltip-bubble">{role.tooltip}</span>
                  </button>
                </div>
              </div>
              <div class="sa-model-default-select">
                <.field
                  type="select"
                  name={"defaults[#{role.key}]"}
                  label={"Default model for #{role.label}"}
                  label_class="sr-only"
                  no_margin={true}
                  options={@model_options}
                  selected={Map.get(@model_defaults, Atom.to_string(role.key))}
                  prompt="Select model"
                />
              </div>
            </div>
          </div>
          <div class="sa-model-defaults-actions">
            <button type="submit" class="sa-btn">Save Defaults</button>
          </div>
        </.form>
      </div>

      <div class="sa-card">
        <div class="sa-row">
          <h2>Active Model List</h2>
          <button class="sa-btn secondary" type="button" phx-click="open_model_modal">
            <.icon name="hero-plus" class="h-4 w-4" /> Add Model
          </button>
        </div>

        <div :if={@models == []} class="sa-empty">
          No models are currently loaded from configuration.
        </div>

        <table :if={@models != []} class="sa-table">
          <thead>
            <tr>
              <th>Model Name</th>
              <th>Input Cost</th>
              <th>Output Cost</th>
              <th>Max Tokens</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={model <- @models}
              class="sa-click-row"
              phx-click="open_model_modal"
              phx-value-id={model.id}
            >
              <td>{model.name}</td>
              <td>{model.input_cost}</td>
              <td>{model.output_cost}</td>
              <td>{model.max_context_tokens}</td>
            </tr>
          </tbody>
        </table>

        <.modal
          :if={@model_modal_open}
          id="model-modal"
          title="Model Details"
          max_width="md"
          on_cancel={JS.push("close_model_modal")}
        >
          <.form for={@model_form} id="model-form" phx-submit="save_model">
            <.input name="model[id]" label="Model ID" value={@model_form.params["id"]} />
            <.input name="model[name]" label="Display Name" value={@model_form.params["name"]} />
            <.input
              name="model[input_cost]"
              label="Input Cost"
              value={@model_form.params["input_cost"]}
            />
            <.input
              name="model[output_cost]"
              label="Output Cost"
              value={@model_form.params["output_cost"]}
            />
            <.input
              name="model[max_context_tokens]"
              label="Max Tokens"
              value={@model_form.params["max_context_tokens"]}
            />
            <div class="sa-row">
              <button type="button" class="sa-btn secondary" phx-click="close_model_modal">
                Cancel
              </button>
              <button type="submit" class="sa-btn">Save Model</button>
            </div>
          </.form>
        </.modal>
      </div>
    </div>
    """
  end
end
