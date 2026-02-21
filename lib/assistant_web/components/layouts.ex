defmodule AssistantWeb.Layouts do
  use AssistantWeb, :html

  attr :flash, :map, default: %{}
  attr :current_scope, :map, default: nil
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <.flash_group flash={@flash} />
    <main class="sa-main">
      {render_slot(@inner_block)}
    </main>
    <div id="sa-autosave-toast" class="sa-autosave-toast" phx-hook="AutosaveToast" role="status" aria-live="polite">
      <span class="sa-autosave-spinner"></span>
      <span data-autosave-message>Saving changes...</span>
    </div>
    """
  end

  attr :inner_content, :any, required: true

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <title>Synaptic Assistant</title>
        <link rel="stylesheet" href={~p"/assets/app.css?v=authrefresh6"} />
      </head>
      <body>
        {@inner_content}
        <script defer src="/vendor/phoenix/phoenix.min.js"></script>
        <script defer src="/vendor/phoenix_live_view/phoenix_live_view.min.js"></script>
        <script defer src="https://unpkg.com/force-graph"></script>
        <script defer src={~p"/assets/app.js?v=accordion1"}></script>
      </body>
    </html>
    """
  end

  attr :flash, :map, required: true

  def flash_group(assigns) do
    info = Phoenix.Flash.get(assigns.flash, :info)
    error = Phoenix.Flash.get(assigns.flash, :error)
    assigns = assign(assigns, info: info, error: error)

    ~H"""
    <section class="sa-flash">
      <.alert :if={@info} color="info" with_icon label={@info} />
      <.alert :if={@error} color="danger" with_icon label={@error} />
    </section>
    """
  end
end
