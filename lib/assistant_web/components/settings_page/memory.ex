defmodule AssistantWeb.Components.SettingsPage.Memory do
  @moduledoc false

  use AssistantWeb, :html

  alias AssistantWeb.Components.SettingsPage.Helpers

  def memory_section(assigns) do
    ~H"""
    <section class="sa-section-stack">
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
            options={Enum.map(@transcript_filter_options.agent_types, &{Helpers.humanize(&1), &1})}
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
            <span class="sa-chip">Status: {Helpers.humanize(@selected_transcript.conversation.status)}</span>
            <span class="sa-chip">Agent: {Helpers.humanize(@selected_transcript.conversation.agent_type)}</span>
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
            options={Enum.map(@memory_filter_options.categories, &{Helpers.humanize(&1), &1})}
            prompt="All categories"
          />
          <.input
            type="select"
            name="memories[source_type]"
            label="Source Type"
            value={@memory_filters["source_type"]}
            options={Enum.map(@memory_filter_options.source_types, &{Helpers.humanize(&1), &1})}
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
              <td>{Helpers.short_id(memory.id)}</td>
              <td>{Helpers.humanize(memory.category)}</td>
              <td>{Helpers.humanize(memory.source_type)}</td>
              <td>{Helpers.format_tags(memory.tags)}</td>
              <td>{Helpers.format_importance(memory.importance)}</td>
              <td>{Helpers.format_time(memory.inserted_at)}</td>
              <td>{Helpers.format_time(memory.accessed_at)}</td>
              <td>{if(memory.source_conversation_id, do: Helpers.short_id(memory.source_conversation_id), else: "-")}</td>
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
      </article>
    </section>
    """
  end
end
