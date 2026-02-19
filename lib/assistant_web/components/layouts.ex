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
        <link rel="stylesheet" href={~p"/assets/app.css"} />
      </head>
      <body>
        {@inner_content}
        <script defer src="/vendor/phoenix/phoenix.min.js"></script>
        <script defer src="/vendor/phoenix_live_view/phoenix_live_view.min.js"></script>
        <script defer src={~p"/assets/app.js"}></script>
      </body>
    </html>
    """
  end

  attr :flash, :map, required: true

  def flash_group(assigns) do
    ~H"""
    <section class="sa-flash">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
    </section>
    """
  end

  attr :kind, :atom, required: true
  attr :flash, :map, required: true

  defp flash(assigns) do
    message = Phoenix.Flash.get(assigns.flash, assigns.kind)
    assigns = assign(assigns, :message, message)

    ~H"""
    <p :if={@message} class={["sa-flash-item", @kind == :error && "sa-flash-error"]}>
      {@message}
    </p>
    """
  end
end
