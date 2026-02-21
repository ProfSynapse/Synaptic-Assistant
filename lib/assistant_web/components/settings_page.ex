defmodule AssistantWeb.Components.SettingsPage do
  @moduledoc false

  use AssistantWeb, :html

  alias Phoenix.LiveView.JS

  alias Assistant.Integrations.Google.Auth, as: GoogleAuth

  import AssistantWeb.Components.DriveSettings, only: [drive_settings: 1]
  import AssistantWeb.Components.ConnectorCard, only: [connector_card: 1]

  def settings_page(assigns) do
    ~H"""
    <div class="sa-settings-shell">
      <aside class={["sa-sidebar", @sidebar_collapsed && "is-collapsed"]}>
        <div class="sa-sidebar-header">
          <div class="sa-sidebar-brand">
            <div class="sa-brand-mark">A</div>
            <span :if={!@sidebar_collapsed}>Synaptic Assistant</span>
          </div>
          <button type="button" class="sa-icon-btn sa-sidebar-toggle" phx-click="toggle_sidebar" aria-label="Toggle sidebar">
            <.icon name="hero-bars-3" class="h-4 w-4" />
          </button>
        </div>

        <nav class="sa-sidebar-nav">
          <.link
            :for={{section, label} <- nav_items()}
            navigate={if(section == "profile", do: ~p"/settings", else: ~p"/settings/#{section}")}
            class={["sa-sidebar-link", section == @section && "is-active"]}
            title={label}
          >
            <.icon name={icon_for(section)} class="h-4 w-4" />
            <span :if={!@sidebar_collapsed}>{label}</span>
          </.link>
        </nav>

        <div class="sa-sidebar-footer">
          <.link href={~p"/settings_users/log-out"} method="delete" class="sa-sidebar-link" title="Log Out">
            <.icon name="hero-arrow-right-on-rectangle" class="h-4 w-4" />
            <span :if={!@sidebar_collapsed}>Log Out</span>
          </.link>
        </div>
      </aside>

      <section class="sa-content">
        <header class="sa-page-header">
          <h1>{page_title(@section)}</h1>
          <p :if={@section == "profile"} class="sa-page-subtitle">
            Welcome back, {profile_first_name(@profile)}.
          </p>
        </header>

        <section :if={@section == "profile"} class="sa-section-stack">
          <article class="sa-card">
            <h2>Account</h2>
            <p class="sa-muted">Manage your profile and account settings.</p>

            <.form
              for={@profile_form}
              as={:profile}
              id="profile-form"
              phx-change="autosave_profile"
              phx-hook="ProfileTimezone"
            >
              <div class="sa-profile-grid">
                <.input
                  name="profile[display_name]"
                  label="Full Name"
                  value={@profile["display_name"]}
                  placeholder="Jane Doe"
                  phx-debounce="500"
                />
                <.input
                  type="email"
                  name="profile[email]"
                  label="Email"
                  value={@profile["email"]}
                  placeholder="jane@company.com"
                  phx-debounce="500"
                />
              </div>
              <input
                id="profile-timezone-input"
                type="hidden"
                name="profile[timezone]"
                value={@profile["timezone"]}
              />

              <div class="sa-form-actions">
                <.link navigate={~p"/settings_users/settings"} class="sa-btn secondary">
                  Change Password
                </.link>
              </div>
            </.form>
          </article>

          <article class="sa-card">
            <h2>Orchestrator System Prompt</h2>
            <p class="sa-muted">
              Tune personality and preferences. This is injected into the orchestrator system prompt.
            </p>

            <.editor_toolbar target="orchestrator-editor-canvas" label="Orchestrator prompt formatting" />

            <div
              id="orchestrator-editor-canvas"
              class="sa-editor-canvas sa-system-prompt-input"
              contenteditable="true"
              role="textbox"
              aria-multiline="true"
              aria-label="Orchestrator system prompt"
              phx-hook="WorkflowRichEditor"
              phx-update="ignore"
              data-save-event="autosave_orchestrator_prompt"
            ><%= Phoenix.HTML.raw(@orchestrator_prompt_html) %></div>
          </article>
        </section>

        <div :if={@section == "models"} class="sa-card">
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

        <div :if={@section == "models"} class="sa-card">
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

        <div :if={@section == "models"} class="sa-card">
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

          <.modal :if={@model_modal_open} id="model-modal" title="Model Details" max_width="md" on_cancel={JS.push("close_model_modal")}>
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

        <div :if={@section == "analytics"} class="sa-card-grid">
          <article class="sa-stat-card">
            <h3>Total Cost (7d)</h3>
            <p>${Float.round(@analytics_snapshot.total_cost, 2)}</p>
          </article>
          <article class="sa-stat-card">
            <h3>Prompt Tokens</h3>
            <p>{@analytics_snapshot.prompt_tokens}</p>
          </article>
          <article class="sa-stat-card">
            <h3>Completion Tokens</h3>
            <p>{@analytics_snapshot.completion_tokens}</p>
          </article>
          <article class="sa-stat-card">
            <h3>Tool Hits</h3>
            <p>{@analytics_snapshot.tool_hits}</p>
          </article>
          <article class="sa-stat-card">
            <h3>Failures</h3>
            <p>{@analytics_snapshot.failures}</p>
          </article>
          <article class="sa-stat-card">
            <h3>Failure Rate</h3>
            <p>{@analytics_snapshot.failure_rate}%</p>
          </article>

          <article class="sa-card">
            <h2>Top Tool Hits</h2>
            <div :if={@analytics_snapshot.top_tools == []} class="sa-muted">No tool activity yet.</div>
            <ul :if={@analytics_snapshot.top_tools != []} class="sa-simple-list">
              <li :for={tool <- @analytics_snapshot.top_tools}>
                <span>{tool.tool_name}</span>
                <strong>{tool.count}</strong>
              </li>
            </ul>
          </article>

          <article class="sa-card">
            <h2>Recent Failures</h2>
            <div :if={@analytics_snapshot.recent_failures == []} class="sa-muted">
              No failures recorded in the selected window.
            </div>
            <ul :if={@analytics_snapshot.recent_failures != []} class="sa-simple-list">
              <li :for={failure <- @analytics_snapshot.recent_failures}>
                <span>{failure.target}</span>
                <span>{format_time(failure.occurred_at)}</span>
              </li>
            </ul>
          </article>
        </div>

        <section :if={@section == "memory"} class="sa-section-stack">
          <article class="sa-card">
            <h2>Transcripts</h2>
            <p class="sa-muted">Search, filter, and read conversation transcripts and related tasks.</p>

            <.form
              for={@transcript_filters_form}
              as={:transcripts}
              id="transcript-filters-form"
              phx-change="filter_transcripts"
              class="sa-transcript-filters"
            >
              <.input
                name="transcripts[query]"
                label="Search"
                value={@transcript_filters["query"]}
                placeholder="Conversation ID or message text"
                phx-debounce="300"
              />
              <.input
                type="select"
                name="transcripts[channel]"
                label="Channel"
                value={@transcript_filters["channel"]}
                options={Enum.map(@transcript_filter_options.channels, &{&1, &1})}
                prompt="All channels"
              />
              <.input
                type="select"
                name="transcripts[status]"
                label="Status"
                value={@transcript_filters["status"]}
                options={Enum.map(@transcript_filter_options.statuses, &{String.capitalize(&1), &1})}
                prompt="All statuses"
              />
              <.input
                type="select"
                name="transcripts[agent_type]"
                label="Agent Type"
                value={@transcript_filters["agent_type"]}
                options={
                  Enum.map(@transcript_filter_options.agent_types, fn v ->
                    {humanize(v), v}
                  end)
                }
                prompt="All agent types"
              />
            </.form>

            <div :if={@transcripts == []} class="sa-empty">
              No transcripts found for current filters.
            </div>

            <table :if={@transcripts != []} class="sa-table">
              <thead>
                <tr>
                  <th>ID</th>
                  <th>Channel</th>
                  <th>Agent</th>
                  <th>Status</th>
                  <th>Messages</th>
                  <th>Last Active</th>
                  <th>Preview</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={transcript <- @transcripts}
                  class="sa-click-row"
                  phx-click="view_transcript"
                  phx-value-id={transcript.id}
                >
                  <td>{short_id(transcript.id)}</td>
                  <td>{transcript.channel || "-"}</td>
                  <td>{humanize(transcript.agent_type)}</td>
                  <td>{humanize(transcript.status)}</td>
                  <td>{transcript.message_count || 0}</td>
                  <td>{format_time(transcript.last_active_at || transcript.inserted_at)}</td>
                  <td>{transcript.preview}</td>
                </tr>
              </tbody>
            </table>

            <section :if={not is_nil(@selected_transcript)} class="sa-subcard">
              <div class="sa-row">
                <h3>Transcript {short_id(@selected_transcript.conversation.id)}</h3>
                <button type="button" class="sa-btn secondary" phx-click="close_transcript">
                  Close
                </button>
              </div>

              <div class="sa-chip-row">
                <span class="sa-chip">Channel: {@selected_transcript.conversation.channel}</span>
                <span class="sa-chip">Status: {humanize(@selected_transcript.conversation.status)}</span>
                <span class="sa-chip">Agent: {humanize(@selected_transcript.conversation.agent_type)}</span>
                <span class="sa-chip">
                  Started: {format_time(
                    @selected_transcript.conversation.started_at || @selected_transcript.conversation.inserted_at
                  )}
                </span>
              </div>

              <div :if={@selected_transcript.related_tasks != []} class="sa-subcard">
                <h4>Related Tasks</h4>
                <table class="sa-table">
                  <thead>
                    <tr>
                      <th>Task</th>
                      <th>Title</th>
                      <th>Status</th>
                      <th>Priority</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={task <- @selected_transcript.related_tasks}>
                      <td>{task.short_id || short_id(task.id)}</td>
                      <td>{task.title}</td>
                      <td>{humanize(task.status)}</td>
                      <td>{humanize(task.priority)}</td>
                    </tr>
                  </tbody>
                </table>
              </div>

              <div class="sa-transcript-messages">
                <article :for={message <- @selected_transcript.messages} class="sa-transcript-message">
                  <header class="sa-row">
                    <strong>{String.upcase(message.role || "unknown")}</strong>
                    <span class="sa-muted">{format_time(message.inserted_at)}</span>
                  </header>
                  <pre class="sa-transcript-content">{display_message_content(message)}</pre>
                </article>
              </div>
            </section>
          </article>

          <article class="sa-card">
            <h2>Memory Entries</h2>
            <p class="sa-muted">Browse memories captured for long-term retrieval.</p>

            <.form
              for={@memory_filters_form}
              as={:memories}
              id="memory-filters-form"
              phx-change="filter_memories"
              class="sa-transcript-filters"
            >
              <.input
                name="memories[query]"
                label="Search"
                value={@memory_filters["query"]}
                placeholder="Memory text"
                phx-debounce="300"
              />
              <.input
                type="select"
                name="memories[category]"
                label="Category"
                value={@memory_filters["category"]}
                options={Enum.map(@memory_filter_options.categories, &{humanize(&1), &1})}
                prompt="All categories"
              />
              <.input
                type="select"
                name="memories[source_type]"
                label="Source Type"
                value={@memory_filters["source_type"]}
                options={Enum.map(@memory_filter_options.source_types, &{humanize(&1), &1})}
                prompt="All source types"
              />
              <.input
                type="select"
                name="memories[tag]"
                label="Tag"
                value={@memory_filters["tag"]}
                options={Enum.map(@memory_filter_options.tags, &{&1, &1})}
                prompt="All tags"
              />
              <.input
                name="memories[source_conversation_id]"
                label="Source Conversation ID"
                value={@memory_filters["source_conversation_id"]}
                placeholder="Conversation UUID"
                phx-debounce="300"
              />
            </.form>

            <div :if={@memories == []} class="sa-empty">
              No memory entries found for current filters.
            </div>

            <table :if={@memories != []} class="sa-table">
              <thead>
                <tr>
                  <th>ID</th>
                  <th>Category</th>
                  <th>Source</th>
                  <th>Tags</th>
                  <th>Importance</th>
                  <th>Created</th>
                  <th>Last Accessed</th>
                  <th>Source Conversation</th>
                  <th>Preview</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={memory <- @memories} class="sa-click-row" phx-click="view_memory" phx-value-id={memory.id}>
                  <td>{short_id(memory.id)}</td>
                  <td>{humanize(memory.category)}</td>
                  <td>{humanize(memory.source_type)}</td>
                  <td>{format_tags(memory.tags)}</td>
                  <td>{format_importance(memory.importance)}</td>
                  <td>{format_time(memory.inserted_at)}</td>
                  <td>{format_time(memory.accessed_at)}</td>
                  <td>{if(memory.source_conversation_id, do: short_id(memory.source_conversation_id), else: "-")}</td>
                  <td>{memory.preview}</td>
                </tr>
              </tbody>
            </table>

            <section :if={not is_nil(@selected_memory)} class="sa-subcard">
              <div class="sa-row">
                <h3>Memory {short_id(@selected_memory.id)}</h3>
                <button type="button" class="sa-btn secondary" phx-click="close_memory">
                  Close
                </button>
              </div>

              <div class="sa-chip-row">
                <span class="sa-chip">Category: {humanize(@selected_memory.category)}</span>
                <span class="sa-chip">Source: {humanize(@selected_memory.source_type)}</span>
                <span class="sa-chip">Importance: {format_importance(@selected_memory.importance)}</span>
                <span class="sa-chip">Created: {format_time(@selected_memory.inserted_at)}</span>
                <span class="sa-chip">Last Accessed: {format_time(@selected_memory.accessed_at)}</span>
                <span :if={@selected_memory.source_conversation_id} class="sa-chip">
                  Source Conversation: {short_id(@selected_memory.source_conversation_id)}
                </span>
                <span :if={@selected_memory.embedding_model} class="sa-chip">
                  Embedding Model: {@selected_memory.embedding_model}
                </span>
                <span :if={not is_nil(@selected_memory.decay_factor)} class="sa-chip">
                  Decay Factor: {format_importance(@selected_memory.decay_factor)}
                </span>
                <span :if={@selected_memory.segment_start_message_id} class="sa-chip">
                  Segment Start: {short_id(@selected_memory.segment_start_message_id)}
                </span>
                <span :if={@selected_memory.segment_end_message_id} class="sa-chip">
                  Segment End: {short_id(@selected_memory.segment_end_message_id)}
                </span>
              </div>

              <div :if={@selected_memory.tags != []} class="sa-chip-row">
                <span :for={tag <- @selected_memory.tags} class="sa-chip">{tag}</span>
              </div>

              <pre class="sa-transcript-content">{@selected_memory.content}</pre>
            </section>
          </article>
        </section>

        <section :if={@section == "apps"} class="sa-card">
          <div class="sa-row">
            <h2>Connected Apps</h2>
            <button class="sa-btn" type="button" phx-click="open_add_app_modal">
              <.icon name="hero-plus" class="h-4 w-4" /> Add App
            </button>
          </div>

          <p>Only approved apps from the platform catalog can be connected.</p>

          <div class="sa-card-grid">
            <.connector_card
              :for={app <- @app_catalog}
              id={app.id}
              name={app.name}
              icon_path={app.icon_path}
              connected={app.id == "google_workspace" and @google_connected}
              on_connect={if app.id == "google_workspace", do: "connect_google", else: ""}
              on_disconnect={if app.id == "google_workspace", do: "disconnect_google", else: ""}
              disconnect_confirm="Disconnect Google Workspace?"
              disabled={app.id != "google_workspace"}
            />
          </div>

          <.drive_settings
            :if={@google_connected}
            connected_drives={@connected_drives}
            available_drives={@available_drives}
            drives_loading={@drives_loading}
            has_google_token={GoogleAuth.configured?()}
          />
          <div :if={!@google_connected} class="sa-drive-settings">
            <h3>Google Drive Access</h3>
            <div class="sa-drive-notice sa-drive-notice--info">
              <.icon name="hero-information-circle" class="h-5 w-5" />
              <span>Connect your Google account above to manage Drive access.</span>
            </div>
          </div>

          <.modal :if={@apps_modal_open} id="apps-modal" title="Add App" max_width="lg" on_cancel={JS.push("close_add_app_modal")}>
            <div class="sa-card-grid">
              <article :for={app <- @app_catalog} class="sa-card">
                <div class="sa-row" style="margin-bottom: 1rem;">
                  <div class="sa-app-title" style="margin-bottom: 0;">
                    <img src={app.icon_path} alt={app.name} class="sa-app-icon" />
                    <h4 style="margin: 0;">{app.name}</h4>
                  </div>
                </div>
                <button
                  type="button"
                  class="sa-btn secondary"
                  style="width: 100%; justify-content: center;"
                  phx-click="add_catalog_app"
                  phx-value-id={app.id}
                >
                  Add
                </button>
              </article>
            </div>
          </.modal>
        </section>

        <section :if={@section == "workflows"} class="sa-card">
          <div class="sa-row">
            <h2>Workflow Cards</h2>
            <button class="sa-btn" type="button" phx-click="new_workflow">
              <.icon name="hero-plus" class="h-4 w-4" /> New Workflow
            </button>
          </div>

          <div :if={@workflows == []} class="sa-empty">
            No workflows found. Create one with `workflow.create`, then manage it here.
          </div>

          <div :if={@workflows != []} class="sa-workflow-grid">
            <article :for={workflow <- @workflows} class="sa-workflow-card">
              <h3>{workflow.name}</h3>
              <div class="sa-row">
                <span>Enabled</span>
                <label class="sa-switch">
                  <input
                    type="checkbox"
                    checked={workflow.enabled}
                    class="sa-switch-input"
                    role="switch"
                    aria-checked={to_string(workflow.enabled)}
                    aria-label={"Toggle #{workflow.name}"}
                    phx-click="toggle_workflow_enabled"
                    phx-value-name={workflow.name}
                    phx-value-enabled={to_string(!workflow.enabled)}
                  />
                  <span class="sa-switch-slider"></span>
                </label>
              </div>
              <p>{workflow.schedule_label}</p>
              <div class="sa-icon-row">
                <.link
                  navigate={~p"/settings/workflows/#{workflow.name}/edit"}
                  class="sa-icon-btn"
                  title="Edit Workflow"
                >
                  <.icon name="hero-pencil-square" class="h-4 w-4" />
                </.link>
                <button
                  type="button"
                  class="sa-icon-btn"
                  title="Duplicate Workflow"
                  phx-click="duplicate_workflow"
                  phx-value-name={workflow.name}
                >
                  <.icon name="hero-document-duplicate" class="h-4 w-4" />
                </button>
              </div>
            </article>
          </div>
        </section>

        <section :if={@section == "skills"} class="sa-card">
          <p class="sa-muted">Toggle runtime permissions by Domain and Skill name.</p>

          <div :if={@skills_permissions == []} class="sa-empty">
            No registered skills were found.
          </div>

          <table :if={@skills_permissions != []} class="sa-table">
            <thead>
              <tr>
                <th>Domain</th>
                <th>Skill</th>
                <th>Enabled</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={perm <- @skills_permissions}>
                <td>{perm.domain_label}</td>
                <td>{perm.skill_label}</td>
                <td>
                  <label class="sa-switch">
                    <input
                      type="checkbox"
                      checked={perm.enabled}
                      class="sa-switch-input"
                      role="switch"
                      aria-checked={to_string(perm.enabled)}
                      aria-label={"Toggle #{perm.skill_label}"}
                      phx-click="toggle_skill_permission"
                      phx-value-skill={perm.id}
                      phx-value-enabled={to_string(!perm.enabled)}
                    />
                    <span class="sa-switch-slider"></span>
                  </label>
                </td>
              </tr>
            </tbody>
          </table>
        </section>

        <section :if={@section == "help"} class="sa-card">
          <div :if={@help_topic == nil}>
            <div class="sa-row">
              <h2>Help Cards</h2>
            </div>
            <.form for={to_form(%{}, as: :help)} phx-change="search_help" id="help-search-form">
              <.input name="help[q]" value={@help_query} placeholder="Search help..." />
            </.form>

            <div class="sa-card-grid">
              <article :for={article <- filtered_help_articles(assigns)} class="sa-card">
                <h3>{article.title}</h3>
                <p>{article.summary}</p>
                <.link navigate={~p"/settings/help?topic=#{article.slug}"} class="sa-btn secondary">
                  Open
                </.link>
              </article>
            </div>
          </div>

          <div :if={@help_topic != nil}>
            <div class="sa-row">
              <h2>{@help_topic.title}</h2>
              <.link navigate={~p"/settings/help"} class="sa-btn secondary">Back to Help</.link>
            </div>

            <ol class="sa-help-steps">
              <li :for={step <- @help_topic.body}>{step}</li>
            </ol>
          </div>
        </section>
      </section>
    </div>
    """
  end

  defp nav_items do
    [
      {"profile", "Profile"},
      {"models", "Models"},
      {"analytics", "Analytics"},
      {"memory", "Memory"},
      {"apps", "Apps & Connections"},
      {"workflows", "Workflows"},
      {"skills", "Skill Permissions"},
      {"help", "Help"}
    ]
  end

  defp icon_for(section) do
    case section do
      "profile" -> "hero-user-circle"
      "models" -> "hero-cube"
      "analytics" -> "hero-chart-bar"
      "memory" -> "hero-document-text"
      "apps" -> "hero-puzzle-piece"
      "workflows" -> "hero-command-line"
      "skills" -> "hero-wrench-screwdriver"
      "help" -> "hero-question-mark-circle"
    end
  end

  defp page_title(section) do
    case section do
      "profile" -> "Profile"
      "models" -> "Models"
      "analytics" -> "Analytics"
      "memory" -> "Memory"
      "apps" -> "Apps & Connections"
      "workflows" -> "Workflows"
      "skills" -> "Skill Permissions"
      "help" -> "Help & Setup"
    end
  end

  defp filtered_help_articles(assigns) do
    query = assigns.help_query |> to_string() |> String.trim() |> String.downcase()

    if query == "" do
      assigns.help_articles
    else
      Enum.filter(assigns.help_articles, fn article ->
        haystack = String.downcase("#{article.title} #{article.summary}")
        String.contains?(haystack, query)
      end)
    end
  end

  defp format_time(nil), do: "Unknown"

  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  defp format_time(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  defp format_time(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, dt, _offset} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
      _ -> iso8601
    end
  end

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_id(_), do: "unknown"

  defp display_message_content(message) do
    content = Map.get(message, :content) || Map.get(message, "content")
    tool_calls = Map.get(message, :tool_calls) || Map.get(message, "tool_calls")
    tool_results = Map.get(message, :tool_results) || Map.get(message, "tool_results")

    cond do
      is_binary(content) and String.trim(content) != "" ->
        content

      is_map(tool_calls) ->
        "Tool calls: " <> Jason.encode!(tool_calls)

      is_map(tool_results) ->
        "Tool results: " <> Jason.encode!(tool_results)

      true ->
        "(no content)"
    end
  end

  defp format_importance(%Decimal{} = value), do: value |> Decimal.to_float() |> Float.round(2)
  defp format_importance(value) when is_float(value), do: Float.round(value, 2)
  defp format_importance(value) when is_integer(value), do: value
  defp format_importance(_), do: "-"

  defp format_tags(tags) when is_list(tags) do
    tags
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [] -> "-"
      values -> Enum.join(values, ", ")
    end
  end

  defp format_tags(_), do: "-"

  defp humanize(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" ->
        "-"

      trimmed ->
        trimmed
        |> String.replace("_", " ")
        |> String.split()
        |> Enum.map_join(" ", &String.capitalize/1)
    end
  end

  defp humanize(value) when is_atom(value), do: value |> Atom.to_string() |> humanize()
  defp humanize(nil), do: "-"
  defp humanize(value), do: to_string(value) |> humanize()

  defp profile_first_name(profile) when is_map(profile) do
    profile
    |> Map.get("display_name", "")
    |> to_string()
    |> String.trim()
    |> case do
      "" ->
        "there"

      full_name ->
        full_name
        |> String.split()
        |> List.first()
    end
  end

  defp profile_first_name(_), do: "there"
end
