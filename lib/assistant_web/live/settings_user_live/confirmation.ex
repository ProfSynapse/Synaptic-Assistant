defmodule AssistantWeb.SettingsUserLive.Confirmation do
  use AssistantWeb, :live_view

  alias Assistant.Accounts
  alias Phoenix.LiveView.JS

  @logo_url "https://picoshare-production-7223.up.railway.app/-emRBGyJeG9"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :logo_url, @logo_url)

    ~H"""
    <Layouts.flash_group flash={@flash} />

    <div class="sa-auth-shell sa-auth-shell-cloud">
      <section class="sa-auth-card sa-auth-card-compact">
        <header class="sa-auth-brand">
          <img src={@logo_url} alt="Synaptic Assistant" class="sa-auth-logo" />
          <div class="sa-auth-brand-copy">
            <p class="sa-auth-product">Synaptic Assistant</p>
            <h1 class="sa-auth-title">Welcome</h1>
            <p class="sa-auth-subtitle">{@settings_user.email}</p>
          </div>
        </header>

        <section class="sa-auth-pane">
          <.form
            :if={!@settings_user.confirmed_at}
            for={@form}
            id="confirmation_form"
            phx-mounted={JS.focus_first()}
            phx-submit="submit"
            action={~p"/settings_users/log-in?_action=confirmed"}
            phx-trigger-action={@trigger_submit}
          >
            <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
            <div class="sa-form-actions">
              <.button
                name={@form[:remember_me].name}
                value="true"
                phx-disable-with="Confirming..."
                class="w-full"
              >
                Confirm and Stay Signed In
              </.button>
              <.button phx-disable-with="Confirming..." class="w-full secondary">
                Confirm for This Session
              </.button>
            </div>
          </.form>

          <.form
            :if={@settings_user.confirmed_at}
            for={@form}
            id="login_form"
            phx-submit="submit"
            phx-mounted={JS.focus_first()}
            action={~p"/settings_users/log-in"}
            phx-trigger-action={@trigger_submit}
          >
            <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
            <%= if @current_scope do %>
              <.button phx-disable-with="Logging in..." class="w-full">Continue</.button>
            <% else %>
              <div class="sa-form-actions">
                <.button
                  name={@form[:remember_me].name}
                  value="true"
                  phx-disable-with="Logging in..."
                  class="w-full"
                >
                  Keep Me Signed In
                </.button>
                <.button phx-disable-with="Logging in..." class="w-full secondary">
                  Sign In This Session
                </.button>
              </div>
            <% end %>
          </.form>

          <p :if={!@settings_user.confirmed_at} class="sa-auth-note">
            Tip: After confirming, you can enable password login in Account Settings.
          </p>
        </section>
      </section>
    </div>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if settings_user = Accounts.get_settings_user_by_magic_link_token(token) do
      form = to_form(%{"token" => token}, as: "settings_user")

      {:ok, assign(socket, settings_user: settings_user, form: form, trigger_submit: false),
       temporary_assigns: [form: nil]}
    else
      {:ok,
       socket
       |> put_flash(:error, "Magic link is invalid or it has expired.")
       |> push_navigate(to: ~p"/settings_users/log-in")}
    end
  end

  @impl true
  def handle_event("submit", %{"settings_user" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: "settings_user"), trigger_submit: true)}
  end
end
