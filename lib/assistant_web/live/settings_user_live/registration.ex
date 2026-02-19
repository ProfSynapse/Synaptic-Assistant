defmodule AssistantWeb.SettingsUserLive.Registration do
  use AssistantWeb, :live_view

  alias Assistant.Accounts
  alias Assistant.Accounts.SettingsUser
  alias Phoenix.LiveView.JS

  @logo_url "https://picoshare-production-7223.up.railway.app/-emRBGyJeG9"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :logo_url, @logo_url)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="sa-auth-shell">
        <header class="sa-auth-top">
          <img src={@logo_url} alt="Synaptic Assistant" class="sa-auth-logo sa-auth-logo-lg" />
          <p class="sa-auth-product">Synaptic Assistant</p>
        </header>

        <section class="sa-auth-card sa-auth-card-compact">
          <h1 class="sa-auth-title">Create Account</h1>
          <p class="sa-auth-subtitle">Use your organizational email to create access.</p>

          <.link href={~p"/settings_users/auth/google"} class="sa-btn secondary sa-auth-google-btn w-full">
            <img src="/images/apps/google.svg" alt="" class="sa-auth-social-icon" />
            Continue with Google
          </.link>

          <div class="sa-auth-divider">
            <span>or sign up with email</span>
          </div>

          <.form for={@form} id="registration_form" phx-submit="save" phx-change="validate">
            <.input
              field={@form[:email]}
              type="email"
              label="Email"
              autocomplete="username"
              required
              phx-mounted={JS.focus()}
            />

            <.button phx-disable-with="Creating account..." class="w-full sa-auth-primary-btn">
              Create Account
            </.button>
          </.form>

          <div class="sa-auth-actions">
            <.link navigate={~p"/settings_users/log-in"} class="sa-btn secondary w-full">
              Back to Password Login
            </.link>
            <.link navigate={~p"/settings_users/magic-link"} class="sa-btn secondary w-full">
              Use Magic Link
            </.link>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(
        _params,
        _session,
        %{assigns: %{current_scope: %{settings_user: settings_user}}} = socket
      )
      when not is_nil(settings_user) do
    {:ok, redirect(socket, to: AssistantWeb.SettingsUserAuth.signed_in_path(socket))}
  end

  def mount(_params, _session, socket) do
    changeset = Accounts.change_settings_user_email(%SettingsUser{}, %{}, validate_unique: false)

    {:ok, assign_form(socket, changeset), temporary_assigns: [form: nil]}
  end

  @impl true
  def handle_event("save", %{"settings_user" => settings_user_params}, socket) do
    case Accounts.register_settings_user(settings_user_params) do
      {:ok, settings_user} ->
        {:ok, _} =
          Accounts.deliver_login_instructions(
            settings_user,
            &url(~p"/settings_users/log-in/#{&1}")
          )

        {:noreply,
         socket
         |> put_flash(
           :info,
           "An email was sent to #{settings_user.email}, please access it to confirm your account."
         )
         |> push_navigate(to: ~p"/settings_users/log-in")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("validate", %{"settings_user" => settings_user_params}, socket) do
    changeset =
      Accounts.change_settings_user_email(%SettingsUser{}, settings_user_params,
        validate_unique: false
      )

    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "settings_user")
    assign(socket, form: form)
  end
end
