defmodule AssistantWeb.Components.SettingsPage.CardGrid do
  @moduledoc false

  use AssistantWeb, :html

  attr :id, :string, required: true
  attr :items, :list, required: true
  attr :search_value, :string, default: ""
  attr :search_event, :string, default: nil
  attr :search_placeholder, :string, default: "Search..."
  attr :empty_message, :string, default: "No items found."

  slot :card, required: true

  def card_grid(assigns) do
    ~H"""
    <div id={@id}>
      <div :if={@search_event} style="margin-bottom: 16px;">
        <form phx-change={@search_event} phx-submit={@search_event}>
          <input
            type="text"
            name="query"
            value={@search_value}
            placeholder={@search_placeholder}
            phx-debounce="300"
            class="sa-search-input"
            autocomplete="off"
          />
        </form>
      </div>

      <div :if={@items == []} class="sa-empty">
        {@empty_message}
      </div>

      <div :if={@items != []} class="sa-card-grid">
        {render_slot(@card, @items)}
      </div>
    </div>
    """
  end
end
