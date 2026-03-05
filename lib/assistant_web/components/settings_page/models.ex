defmodule AssistantWeb.Components.SettingsPage.Models do
  @moduledoc false

  use AssistantWeb, :html

  alias Phoenix.LiveView.JS

  def models_section(assigns) do
    ~H"""
    <div>
      <div class="sa-card">
        <div class="sa-row">
          <h2>Active Model List</h2>
          <button
            :if={@model_catalog_editable}
            class="sa-btn secondary"
            type="button"
            phx-click="open_model_modal"
          >
            <.icon name="hero-plus" class="h-4 w-4" /> Add Model
          </button>
        </div>
        <p :if={!@model_catalog_editable} class="sa-muted">
          Admins manage the shared model catalog. You can still use any models already in the list above.
        </p>

        <.form
          for={@active_model_filter_form}
          id="active-model-filter-form"
          class="sa-model-list-toolbar"
          phx-change="filter_active_models"
        >
          <div class="sa-model-default-select">
            <.field
              type="text"
              field={@active_model_filter_form[:q]}
              label="Search active models"
              placeholder="Search by name, id, or provider..."
              no_margin
            />
          </div>
          <div class="sa-model-default-select">
            <.field
              type="select"
              name="active_models[provider]"
              label="Provider"
              value={@active_model_provider}
              options={@active_model_provider_options}
              no_margin
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
                    :if={@model_catalog_editable}
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
          :if={@model_modal_open and @model_catalog_editable}
          id="model-modal"
          title="Add OpenRouter Models"
          max_width="xl"
          on_cancel={JS.push("close_model_modal")}
        >
          <.form for={@model_library_form} id="model-library-form" phx-change="search_model_library">
            <.field
              type="text"
              field={@model_library_form[:q]}
              label="Search OpenRouter models"
              placeholder="Search by model name or id (for example gpt-oss, claude, gemini...)"
              no_margin
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
