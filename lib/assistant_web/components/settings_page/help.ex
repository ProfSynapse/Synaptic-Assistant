defmodule AssistantWeb.Components.SettingsPage.Help do
  @moduledoc false

  use AssistantWeb, :html

  alias AssistantWeb.Components.SettingsPage.Helpers

  def help_section(assigns) do
    ~H"""
    <section class="sa-card">
      <div :if={@help_topic == nil}>
        <div class="sa-row">
          <h2>Help Cards</h2>
        </div>
        <.form for={to_form(%{}, as: :help)} phx-change="search_help" id="help-search-form">
          <.input name="help[q]" value={@help_query} placeholder="Search help..." />
        </.form>

        <div class="sa-card-grid">
          <article :for={article <- Helpers.filtered_help_articles(@help_articles, @help_query)} class="sa-card">
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
    """
  end
end
