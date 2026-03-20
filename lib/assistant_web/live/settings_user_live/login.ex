defmodule AssistantWeb.SettingsUserLive.Login do
  use AssistantWeb, :live_view

  alias Assistant.Accounts
  alias Assistant.Deployment
  alias Phoenix.LiveView.JS

  @logo_url "https://picoshare-production-7223.up.railway.app/-emRBGyJeG9"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :logo_url, @logo_url)

    ~H"""
    <Layouts.flash_group flash={@flash} />

    <div class="sa-auth-shell sa-auth-shell-cloud">
      <header class="sa-auth-top">
        <img src={@logo_url} alt="Synaptic Assistant" class="sa-auth-logo-wide" />
        <p class="sa-auth-wordmark" aria-hidden="true">Assistant</p>
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
          <.field
            readonly={!!@current_scope}
            field={f[:email]}
            type="email"
            label="Email"
            autocomplete="email"
            required
            no_margin
            phx-mounted={JS.focus()}
          />
          <.field
            field={@form[:password]}
            type="password"
            label="Password"
            autocomplete="current-password"
            required
            no_margin
          />
          <.button class="w-full sa-auth-primary-btn" name={@form[:remember_me].name} value="true">
            Sign In
          </.button>
        </.form>

        <div :if={!Deployment.self_hosted?()}>
          <div class="sa-auth-divider">
            <span>or</span>
          </div>

          <.link href={~p"/settings_users/auth/google"} class="sa-btn secondary sa-auth-google-btn w-full">
            <img src="/images/apps/google.svg" alt="" class="sa-auth-social-icon" />
            Sign in with Google
          </.link>
        </div>

        <div class="sa-auth-secondary-links">
          <.link
            :if={!Deployment.self_hosted?()}
            navigate={~p"/settings_users/magic-link"}
            class="sa-auth-inline-link"
          >
            Send Magic Link
          </.link>
          <.link
            :if={!Deployment.self_hosted?()}
            navigate={~p"/settings_users/register"}
            class="sa-auth-inline-link"
          >
            Create Account
          </.link>
        </div>
      </section>

      <section :if={@live_action == :magic} class="sa-auth-card sa-auth-login-card">
        <div :if={!@email_sent}>
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
            <.field
              readonly={!!@current_scope}
              field={f[:email]}
              type="email"
              label="Email"
              autocomplete="email"
              required
              no_margin
              phx-mounted={JS.focus()}
            />
            <.button class="w-full sa-auth-primary-btn">Send Sign-In Link</.button>
          </.form>
        </div>

        <div :if={@email_sent}>
          <div class="flex justify-center mb-4">
            <.icon name="hero-check-circle" class="size-12 text-emerald-400" />
          </div>
          <h1 class="sa-auth-title">Check your inbox</h1>
          <p class="sa-auth-subtitle">
            We sent a sign-in link to <strong>{@submitted_email}</strong>. It expires in 10 minutes.
          </p>

          <div :if={local_mail_adapter?()} class="sa-auth-alert">
            <.icon name="hero-information-circle" class="size-6 shrink-0" />
            <div>
              <p>Local mail adapter is active.</p>
              <p>
                View delivered emails in <.link href="/dev/mailbox">/dev/mailbox</.link>.
              </p>
            </div>
          </div>

          <button phx-click="reset_magic" class="w-full sa-auth-primary-btn mt-4" style="background: transparent; border: 1px solid rgba(255,255,255,0.2); color: rgba(255,255,255,0.7);">
            Try a different email
          </button>
        </div>

        <div class="sa-auth-secondary-links">
          <.link navigate={~p"/settings_users/log-in"} class="sa-auth-inline-link">
            Back to password login
          </.link>
          <.link
            :if={!Deployment.self_hosted?()}
            navigate={~p"/settings_users/register"}
            class="sa-auth-inline-link"
          >
            Create Account
          </.link>
        </div>
      </section>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    cond do
      Accounts.admin_bootstrap_available?() ->
        {:ok, push_navigate(socket, to: ~p"/setup")}

      Deployment.self_hosted?() and socket.assigns.live_action == :magic ->
        {:ok, push_navigate(socket, to: ~p"/settings_users/log-in")}

      true ->
        email =
          Phoenix.Flash.get(socket.assigns.flash, :email) ||
            get_in(socket.assigns, [
              :current_scope,
              Access.key(:settings_user),
              Access.key(:email)
            ])

        form = to_form(%{"email" => email}, as: "settings_user")

        {:ok, assign(socket, form: form, trigger_submit: false, email_sent: false, submitted_email: nil)}
    end
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

    {:noreply, assign(socket, email_sent: true, submitted_email: email)}
  end

  def handle_event("reset_magic", _params, socket) do
    {:noreply, assign(socket, email_sent: false, submitted_email: nil)}
  end

  defp local_mail_adapter? do
    Assistant.Mailer.local_preview?()
  end
end
