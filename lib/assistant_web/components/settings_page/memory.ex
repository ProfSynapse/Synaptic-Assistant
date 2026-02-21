defmodule AssistantWeb.Components.SettingsPage.Memory do
  @moduledoc false

  use AssistantWeb, :html

  alias AssistantWeb.Components.SettingsPage.Helpers

  def memory_section(assigns) do
    ~H"""
    <section class="sa-section-stack">
      <article class="sa-card sa-memory-filter-card">
        <h2>Knowledge Graph</h2>
        <p class="sa-muted">
          Explore the assistant brain as an interactive graph. Query, timeframe, and type filters apply across the entire section.
        </p>

        <.form
          for={@graph_filters_form}
          as={:global}
          id="memory-global-filters-form"
          phx-change="update_global_filters"
          class="sa-memory-global-filters"
        >
          <.input
            name="global[query]"
            label="Search"
            value={@graph_filters["query"]}
            placeholder="Entity, memory content, or transcript ID"
            phx-debounce="300"
          />
          <div class="sa-model-default-select">
            <.input
              type="select"
              name="global[timeframe]"
              label="Timeframe"
              value={@graph_filters["timeframe"]}
              options={@graph_filter_options.timeframes}
            />
          </div>
          <div class="sa-model-default-select">
            <.input
              type="select"
              name="global[type]"
              label="Type"
              value={@graph_filters["type"]}
              options={@graph_filter_options.types}
            />
          </div>
        </.form>
      </article>

      <article class="sa-card">
        <div class="sa-row">
          <h2>Assistant Brain Map</h2>
          <span class="sa-chip">Nodes: {length(@graph_data.nodes)}</span>
        </div>
        <p class="sa-muted">Drag to pan, scroll to zoom, and click nodes to expand context.</p>

        <div
          id="sa-knowledge-graph"
          class="sa-knowledge-graph-shell"
          phx-hook="KnowledgeGraph"
          phx-update="ignore"
        >
          <div data-graph-canvas class="sa-knowledge-graph-canvas"></div>
          <div class="sa-graph-controls" aria-label="Knowledge graph controls">
            <button type="button" class="sa-graph-control-btn" data-graph-control="zoom-in" title="Zoom in">
              <.icon name="hero-plus" class="h-4 w-4" />
            </button>
            <button type="button" class="sa-graph-control-btn" data-graph-control="zoom-out" title="Zoom out">
              <.icon name="hero-minus-mini" class="h-4 w-4" />
            </button>
            <button type="button" class="sa-graph-control-btn" data-graph-control="reset" title="Reset view">
              <.icon name="hero-home-mini" class="h-4 w-4" />
            </button>
          </div>
        </div>
      </article>

      <section class="sa-memory-accordions">
        <details class="sa-accordion" open>
          <summary>Transcripts ({length(@transcripts)})</summary>
          <div class="sa-accordion-body">
            <p class="sa-muted">Raw transcript records matching the global filters.</p>

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
                  <td>{Helpers.short_id(transcript.id)}</td>
                  <td>{transcript.channel || "-"}</td>
                  <td>{Helpers.humanize(transcript.agent_type)}</td>
                  <td>{Helpers.humanize(transcript.status)}</td>
                  <td>{transcript.message_count || 0}</td>
                  <td>{Helpers.format_time(transcript.last_active_at || transcript.inserted_at)}</td>
                  <td>{transcript.preview}</td>
                </tr>
              </tbody>
            </table>

            <section :if={not is_nil(@selected_transcript)} class="sa-subcard">
              <div class="sa-row">
                <h3>Transcript {Helpers.short_id(@selected_transcript.conversation.id)}</h3>
                <button type="button" class="sa-btn secondary" phx-click="close_transcript">
                  Close
                </button>
              </div>

              <div class="sa-chip-row">
                <span class="sa-chip">Channel: {@selected_transcript.conversation.channel}</span>
                <span class="sa-chip">
                  Status: {Helpers.humanize(@selected_transcript.conversation.status)}
                </span>
                <span class="sa-chip">
                  Agent: {Helpers.humanize(@selected_transcript.conversation.agent_type)}
                </span>
                <span class="sa-chip">
                  Started: {Helpers.format_time(
                    @selected_transcript.conversation.started_at ||
                      @selected_transcript.conversation.inserted_at
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
                      <td>{task.short_id || Helpers.short_id(task.id)}</td>
                      <td>{task.title}</td>
                      <td>{Helpers.humanize(task.status)}</td>
                      <td>{Helpers.humanize(task.priority)}</td>
                    </tr>
                  </tbody>
                </table>
              </div>

              <div class="sa-transcript-messages">
                <article :for={message <- @selected_transcript.messages} class="sa-transcript-message">
                  <header class="sa-row">
                    <strong>{String.upcase(message.role || "unknown")}</strong>
                    <span class="sa-muted">{Helpers.format_time(message.inserted_at)}</span>
                  </header>
                  <pre class="sa-transcript-content">{Helpers.display_message_content(message)}</pre>
                </article>
              </div>
            </section>
          </div>
        </details>

        <details class="sa-accordion" open>
          <summary>Memory Entries ({length(@memories)})</summary>
          <div class="sa-accordion-body">
            <p class="sa-muted">Raw memory records matching the global filters.</p>

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
                  <td>{Helpers.short_id(memory.id)}</td>
                  <td>{Helpers.humanize(memory.category)}</td>
                  <td>{Helpers.humanize(memory.source_type)}</td>
                  <td>{Helpers.format_tags(memory.tags)}</td>
                  <td>{Helpers.format_importance(memory.importance)}</td>
                  <td>{Helpers.format_time(memory.inserted_at)}</td>
                  <td>{Helpers.format_time(memory.accessed_at)}</td>
                  <td>
                    {if(memory.source_conversation_id, do: Helpers.short_id(memory.source_conversation_id), else: "-")}
                  </td>
                  <td>{memory.preview}</td>
                </tr>
              </tbody>
            </table>

            <section :if={not is_nil(@selected_memory)} class="sa-subcard">
              <div class="sa-row">
                <h3>Memory {Helpers.short_id(@selected_memory.id)}</h3>
                <button type="button" class="sa-btn secondary" phx-click="close_memory">
                  Close
                </button>
              </div>

              <div class="sa-chip-row">
                <span class="sa-chip">Category: {Helpers.humanize(@selected_memory.category)}</span>
                <span class="sa-chip">Source: {Helpers.humanize(@selected_memory.source_type)}</span>
                <span class="sa-chip">Importance: {Helpers.format_importance(@selected_memory.importance)}</span>
                <span class="sa-chip">Created: {Helpers.format_time(@selected_memory.inserted_at)}</span>
                <span class="sa-chip">Last Accessed: {Helpers.format_time(@selected_memory.accessed_at)}</span>
                <span :if={@selected_memory.source_conversation_id} class="sa-chip">
                  Source Conversation: {Helpers.short_id(@selected_memory.source_conversation_id)}
                </span>
                <span :if={@selected_memory.embedding_model} class="sa-chip">
                  Embedding Model: {@selected_memory.embedding_model}
                </span>
                <span :if={not is_nil(@selected_memory.decay_factor)} class="sa-chip">
                  Decay Factor: {Helpers.format_importance(@selected_memory.decay_factor)}
                </span>
                <span :if={@selected_memory.segment_start_message_id} class="sa-chip">
                  Segment Start: {Helpers.short_id(@selected_memory.segment_start_message_id)}
                </span>
                <span :if={@selected_memory.segment_end_message_id} class="sa-chip">
                  Segment End: {Helpers.short_id(@selected_memory.segment_end_message_id)}
                </span>
              </div>

              <div :if={@selected_memory.tags != []} class="sa-chip-row">
                <span :for={tag <- @selected_memory.tags} class="sa-chip">{tag}</span>
              </div>

              <pre class="sa-transcript-content">{@selected_memory.content}</pre>
            </section>
          </div>
        </details>
      </section>
    </section>
    """
  end
end
