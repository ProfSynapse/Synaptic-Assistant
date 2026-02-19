defmodule AssistantWeb.SettingsUserLive.Login do
  use AssistantWeb, :live_view

  alias Assistant.Accounts
  alias Phoenix.LiveView.JS

  @logo_url "https://picoshare-production-7223.up.railway.app/-emRBGyJeG9"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :logo_url, @logo_url)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="sa-auth-shell sa-auth-shell-cloud">
        <header class="sa-auth-top">
          <img src={@logo_url} alt="Synaptic Assistant" class="sa-auth-logo-wide" />
        </header>

        <section :if={@live_action != :magic} class="sa-auth-card sa-auth-login-card">
          <.form
            :let={f}
            for={@form}
            id="login_form_password"
            action={~p"/settings_users/log-in"}
            phx-submit="submit_password"
            phx-trigger-action={@trigger_submit}
          >
            <.input
              readonly={!!@current_scope}
              field={f[:email]}
              type="email"
              label="Email"
              autocomplete="email"
              required
              phx-mounted={JS.focus()}
            />
            <.input
              field={@form[:password]}
              type="password"
              label="Password"
              autocomplete="current-password"
              required
            />
            <.button class="w-full sa-auth-primary-btn" name={@form[:remember_me].name} value="true">
              Sign In
            </.button>
          </.form>

          <div class="sa-auth-divider">
            <span>or continue with</span>
          </div>

          <.link href={~p"/settings_users/auth/google"} class="sa-btn secondary sa-auth-google-btn w-full">
            <img src="/images/apps/google.svg" alt="" class="sa-auth-social-icon" />
            Sign in with Google
          </.link>

          <div class="sa-auth-secondary-links">
            <.link navigate={~p"/settings_users/register"} class="sa-auth-inline-link">
              Create account
            </.link>
            <.link navigate={~p"/settings_users/magic-link"} class="sa-auth-inline-link">
              Use magic link
            </.link>
          </div>
        </section>

        <section :if={@live_action == :magic} class="sa-auth-card sa-auth-login-card">
          <h1 class="sa-auth-title">Magic Link Login</h1>
          <p class="sa-auth-subtitle">Enter your email and we will send a one-time sign-in link.</p>

          <div :if={local_mail_adapter?()} class="sa-auth-alert">
            <.icon name="hero-information-circle" class="size-6 shrink-0" />
            <div>
              <p>Local mail adapter is active.</p>
              <p>
                View delivered emails in <.link href="/dev/mailbox">/dev/mailbox</.link>.
              </p>
            </div>
          </div>

          <.form
            :let={f}
            for={@form}
            id="login_form_magic"
            action={~p"/settings_users/log-in"}
            phx-submit="submit_magic"
          >
            <.input
              readonly={!!@current_scope}
              field={f[:email]}
              type="email"
              label="Email"
              autocomplete="email"
              required
              phx-mounted={JS.focus()}
            />
            <.button class="w-full sa-auth-primary-btn">Send Sign-In Link</.button>
          </.form>

          <div class="sa-auth-secondary-links">
            <.link navigate={~p"/settings_users/log-in"} class="sa-auth-inline-link">
              Back to password login
            </.link>
            <.link navigate={~p"/settings_users/register"} class="sa-auth-inline-link">
              Create account
            </.link>
          </div>
        </section>

        <p :if={@live_action != :magic} class="sa-auth-note">
          Use your organizational email tied to Synaptic Assistant access.
        </p>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:settings_user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "settings_user")

    {:ok, assign(socket, form: form, trigger_submit: false)}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  def handle_event("submit_magic", %{"settings_user" => %{"email" => email}}, socket) do
    if settings_user = Accounts.get_settings_user_by_email(email) do
      Accounts.deliver_login_instructions(
        settings_user,
        &url(~p"/settings_users/log-in/#{&1}")
      )
    end

    info =
      "If your email is in our system, you will receive instructions for logging in shortly."

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> push_navigate(to: ~p"/settings_users/log-in")}
  end

  defp local_mail_adapter? do
    Application.get_env(:assistant, Assistant.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
