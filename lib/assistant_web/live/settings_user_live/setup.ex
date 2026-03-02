# lib/assistant_web/live/settings_user_live/setup.ex — First-admin setup page.
#
# Shown only when no admin exists. Creates a settings_user, confirms them,
# and claims the bootstrap admin role. After success, uses phx-trigger-action
# to POST to the session controller for login, redirecting to /admin.

defmodule AssistantWeb.SettingsUserLive.Setup do
  use AssistantWeb, :live_view

  alias Assistant.Accounts
  alias Assistant.Accounts.SettingsUser
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

      <section class="sa-auth-card sa-auth-card-compact">
        <h1 class="sa-auth-title">Set Up Your Admin Account</h1>
        <p class="sa-auth-subtitle">
          No administrator exists yet. Create the first account to get started.
        </p>

        <.form for={@form} id="setup_form" phx-submit="save" phx-change="validate">
          <.field
            field={@form[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            required
            no_margin
            phx-mounted={JS.focus()}
          />

          <.field
            field={@form[:password]}
            type="password"
            label="Password"
            autocomplete="new-password"
            required
            no_margin
          />

          <.button phx-disable-with="Creating admin account..." class="w-full sa-auth-primary-btn">
            Create Admin Account
          </.button>
        </.form>
      </section>

      <%!-- Hidden form that auto-submits to the session controller after successful registration --%>
      <.form
        for={@login_form}
        id="setup_login_form"
        action={~p"/settings_users/log-in"}
        phx-trigger-action={@trigger_submit}
        class="hidden"
      >
        <input type="hidden" name="_action" value="setup_admin" />
        <input type="hidden" name={@login_form[:email].name} value={@login_form[:email].value} />
        <input
          type="hidden"
          name={@login_form[:password].name}
          value={@login_form[:password].value}
        />
      </.form>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if Accounts.admin_bootstrap_available?() do
      changeset = Accounts.change_settings_user_email(%SettingsUser{}, %{}, validate_unique: false)

      {:ok,
       socket
       |> assign(trigger_submit: false)
       |> assign(login_form: to_form(%{"email" => "", "password" => ""}, as: "settings_user"))
       |> assign_form(changeset), temporary_assigns: [form: nil]}
    else
      {:ok, push_navigate(socket, to: ~p"/settings_users/log-in")}
    end
  end

  @impl true
  def handle_event("save", %{"settings_user" => params}, socket) do
    case Accounts.register_and_bootstrap_admin(params) do
      {:ok, _settings_user} ->
        login_form = to_form(%{"email" => params["email"], "password" => params["password"]},
          as: "settings_user"
        )

        {:noreply,
         socket
         |> assign(trigger_submit: true)
         |> assign(login_form: login_form)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("validate", %{"settings_user" => params}, socket) do
    changeset =
      %SettingsUser{}
      |> Accounts.change_settings_user_email(params, validate_unique: false)
      |> SettingsUser.password_changeset(params, hash_password: false)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, form: to_form(changeset, as: "settings_user"))
  end
end
