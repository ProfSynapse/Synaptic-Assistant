defmodule AssistantWeb.Components.SettingsPage.Models do
  @moduledoc false

  use AssistantWeb, :html

  alias Phoenix.LiveView.JS

  def models_section(assigns) do
    ~H"""
    <div>
      <div class="sa-card">
        <div class="sa-row" style="align-items: baseline;">
          <h2>Model Providers</h2>
        </div>
        <p class="sa-muted">
          Connect providers to make their models available for role defaults and active model selection.
        </p>
        <div class="sa-card-grid">
          <article class="sa-card">
            <div class="sa-row">
              <div class="sa-app-title" style="margin-bottom: 0; flex: 1;">
                <img src="/images/apps/openrouter.svg" alt="OpenRouter" class="sa-app-icon" />
                <h3>OpenRouter</h3>
              </div>
              <div class="sa-row" style="gap: 0.5rem;">
                <button
                  type="button"
                  class="sa-icon-btn"
                  phx-click="toggle_openrouter_key_form"
                  aria-label="Use OpenRouter API key"
                  aria-expanded={to_string(@openrouter_key_form_open)}
                  title="Use API key"
                >
                  <.icon name="hero-key" class="h-4 w-4" />
                </button>
                <button
                  :if={!@openrouter_connected}
                  type="button"
                  class="sa-btn"
                  phx-click="connect_openrouter"
                >
                  Connect
                </button>
                <button
                  :if={@openrouter_connected}
                  type="button"
                  class="sa-btn secondary"
                  phx-click="disconnect_openrouter"
                  data-confirm="Disconnect OpenRouter? The assistant will use the system-level API key instead."
                >
                  Disconnect
                </button>
              </div>
            </div>
            <p class="sa-muted" style="margin-top: 0.5rem;">
              Status:
              <span :if={@openrouter_connected}>Connected</span>
              <span :if={!@openrouter_connected}>Not connected</span>
            </p>
            <div :if={@openrouter_key_form_open} style="margin-top: 0.75rem;">
              <.form for={@openrouter_key_form} id="openrouter-key-form" phx-submit="save_openrouter_api_key">
                <.input
                  type="password"
                  field={@openrouter_key_form[:api_key]}
                  label="OpenRouter API key"
                  required
                />
                <button type="submit" class="sa-btn secondary">Validate & Connect</button>
              </.form>
            </div>
          </article>

          <article class="sa-card">
            <div class="sa-row">
              <div class="sa-app-title" style="margin-bottom: 0; flex: 1;">
                <img src="/images/apps/openai.svg" alt="OpenAI" class="sa-app-icon" />
                <h3>OpenAI</h3>
              </div>
              <div class="sa-row" style="gap: 0.5rem;">
                <button
                  type="button"
                  class="sa-icon-btn"
                  phx-click="toggle_openai_key_form"
                  aria-label="Use OpenAI API key"
                  aria-expanded={to_string(@openai_key_form_open)}
                  title="Use API key"
                >
                  <.icon name="hero-key" class="h-4 w-4" />
                </button>
                <button :if={!@openai_connected} type="button" class="sa-btn" phx-click="connect_openai">
                  Connect
                </button>
                <button
                  :if={@openai_connected}
                  type="button"
                  class="sa-btn secondary"
                  phx-click="disconnect_openai"
                  data-confirm="Disconnect OpenAI?"
                >
                  Disconnect
                </button>
              </div>
            </div>
            <p class="sa-muted" style="margin-top: 0.5rem;">
              Status:
              <span :if={@openai_connected}>Connected</span>
              <span :if={!@openai_connected}>Not connected</span>
            </p>
            <p class="sa-muted" style="margin-top: 0.25rem;">
              Connect starts ChatGPT OAuth (Codex-compatible). Use the key icon to manually add your OpenAI API key.
            </p>
            <div :if={@openai_key_form_open} style="margin-top: 0.75rem;">
              <.form for={@openai_key_form} id="openai-key-form" phx-submit="save_openai_api_key">
                <.input type="password" field={@openai_key_form[:api_key]} label="OpenAI API key" required />
                <button type="submit" class="sa-btn secondary">Validate & Connect</button>
              </.form>
            </div>
          </article>
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

        <.form
          for={@active_model_filter_form}
          id="active-model-filter-form"
          class="sa-model-list-toolbar"
          phx-change="filter_active_models"
        >
          <div class="sa-model-default-select">
            <.input
              type="text"
              field={@active_model_filter_form[:q]}
              label="Search active models"
              placeholder="Search by name, id, or provider..."
            />
          </div>
          <div class="sa-model-default-select">
            <.input
              type="select"
              name="active_models[provider]"
              label="Provider"
              value={@active_model_provider}
              options={@active_model_provider_options}
            />
          </div>
        </.form>

        <div :if={@active_model_all_models == []} class="sa-empty">
          No models are currently loaded from configuration.
        </div>

        <div :if={@active_model_all_models != [] and @models == []} class="sa-empty">
          No models match your current search/filter.
        </div>

        <div :if={@models != []} class="sa-model-table-shell">
          <table class="sa-table sa-model-table sa-table-zebra">
            <thead>
              <tr>
                <th>Model Name</th>
                <th>Model ID</th>
                <th>Input Cost</th>
                <th>Output Cost</th>
                <th>Max Tokens</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={model <- @models}>
                <td>{model.name}</td>
                <td><code>{model.id}</code></td>
                <td>{model.input_cost}</td>
                <td>{model.output_cost}</td>
                <td>{model.max_context_tokens}</td>
                <td>
                  <button
                    type="button"
                    class="sa-icon-btn danger"
                    phx-click="remove_model_from_catalog"
                    phx-value-id={model.id}
                    data-confirm={"Remove #{model.name} from your catalog?"}
                    aria-label={"Remove #{model.name}"}
                    title={"Remove #{model.name}"}
                  >
                    <.icon name="hero-x-mark" class="h-4 w-4" />
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <.modal
          :if={@model_modal_open}
          id="model-modal"
          title="Add OpenRouter Models"
          max_width="xl"
          on_cancel={JS.push("close_model_modal")}
        >
          <.form for={@model_library_form} id="model-library-form" phx-change="search_model_library">
            <.input
              type="text"
              field={@model_library_form[:q]}
              label="Search OpenRouter models"
              placeholder="Search by model name or id (for example gpt-oss, claude, gemini...)"
            />
          </.form>

          <div :if={@model_library_error} class="sa-empty" style="margin-top: 0.75rem;">
            {@model_library_error}
          </div>

          <div :if={@model_library_models == [] and !@model_library_error} class="sa-empty" style="margin-top: 0.75rem;">
            No models match your search.
          </div>

          <table :if={@model_library_models != []} class="sa-table" style="margin-top: 0.75rem;">
            <thead>
              <tr>
                <th>Model Name</th>
                <th>Model ID</th>
                <th>Input Cost</th>
                <th>Output Cost</th>
                <th>Max Tokens</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={model <- @model_library_models}>
                <td>{model.name}</td>
                <td><code>{model.id}</code></td>
                <td>{model.input_cost}</td>
                <td>{model.output_cost}</td>
                <td>{model.max_context_tokens}</td>
                <td>
                  <button
                    :if={!MapSet.member?(@catalog_model_ids, model.id)}
                    type="button"
                    class="sa-btn"
                    phx-click="add_model_from_library"
                    phx-value-id={model.id}
                    phx-value-name={model.name}
                    phx-value-input_cost={model.input_cost}
                    phx-value-output_cost={model.output_cost}
                    phx-value-max_context_tokens={model.max_context_tokens}
                  >
                    Add
                  </button>
                  <button
                    :if={MapSet.member?(@catalog_model_ids, model.id)}
                    type="button"
                    class="sa-icon-btn danger"
                    phx-click="remove_model_from_catalog"
                    phx-value-id={model.id}
                    aria-label={"Remove #{model.name}"}
                    title={"Remove #{model.name}"}
                  >
                    <.icon name="hero-x-mark" class="h-4 w-4" />
                  </button>
                </td>
              </tr>
            </tbody>
          </table>

          <div class="sa-row" style="margin-top: 0.75rem;">
            <button type="button" class="sa-btn secondary" phx-click="refresh_model_library">
              Refresh
            </button>
            <button type="button" class="sa-btn secondary" phx-click="close_model_modal">
              Done
            </button>
          </div>
        </.modal>
      </div>
    </div>
    """
  end
end
