defmodule AssistantWeb.Layouts do
  use AssistantWeb, :html

  attr :flash, :map, default: %{}
  attr :current_scope, :map, default: nil
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <.impersonation_banner :if={@current_scope && @current_scope.impersonating?} current_scope={@current_scope} />
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
        <link rel="stylesheet" href={~p"/assets/app.css?v=drive-scroll-fix2"} />
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

  attr :current_scope, :map, required: true

  defp impersonation_banner(assigns) do
    ~H"""
    <div
      style="
        position: sticky; top: 0; z-index: 9999;
        background: var(--sa-warning-bg, #fef3c7);
        border-bottom: 2px solid var(--sa-warning-border, #f59e0b);
        padding: 8px 16px;
        display: flex; align-items: center; justify-content: center; gap: 12px;
        font-size: 0.875rem; font-weight: 500;
        color: var(--sa-warning-text, #92400e);
      "
      role="alert"
    >
      <.icon name="hero-eye" class="h-4 w-4" />
      <span>
        Viewing as <strong>{@current_scope.settings_user.email}</strong>
      </span>
      <form method="post" action={~p"/settings_users/impersonate"} style="margin: 0;">
        <input type="hidden" name="_method" value="delete" />
        <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
        <button
          type="submit"
          style="
            background: var(--sa-warning-border, #f59e0b);
            color: white;
            border: none;
            padding: 4px 12px;
            border-radius: 4px;
            font-size: 0.8rem;
            font-weight: 600;
            cursor: pointer;
          "
        >
          Return to Admin
        </button>
      </form>
    </div>
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
