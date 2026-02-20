defmodule AssistantWeb.SettingsUserLive.Settings do
  use AssistantWeb, :live_view

  on_mount {AssistantWeb.SettingsUserAuth, :require_sudo_mode}

  alias Assistant.Accounts

  @logo_url "https://picoshare-production-7223.up.railway.app/-emRBGyJeG9"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :logo_url, @logo_url)

    ~H"""
    <Layouts.flash_group flash={@flash} />

    <div class="sa-auth-shell sa-auth-shell-cloud">
      <section class="sa-auth-card">
          <header class="sa-auth-brand">
            <img src={@logo_url} alt="Synaptic Assistant" class="sa-auth-logo" />
            <div class="sa-auth-brand-copy">
              <p class="sa-auth-product">Synaptic Assistant</p>
              <h1 class="sa-auth-title">Account Settings</h1>
              <p class="sa-auth-subtitle">Manage email and password for your operator account.</p>
            </div>
          </header>

          <div class="sa-auth-form-grid">
            <section class="sa-auth-pane">
              <h2>Update Email</h2>
              <.form for={@email_form} id="email_form" phx-submit="update_email" phx-change="validate_email">
                <.field
                  field={@email_form[:email]}
                  type="email"
                  label="Email"
                  autocomplete="username"
                  required
                  no_margin
                />
                <.button phx-disable-with="Changing..." class="w-full">Change Email</.button>
              </.form>
            </section>

            <section class="sa-auth-pane">
              <h2>Change Password</h2>
              <.form
                for={@password_form}
                id="password_form"
                action={~p"/settings_users/update-password"}
                method="post"
                phx-change="validate_password"
                phx-submit="update_password"
                phx-trigger-action={@trigger_submit}
              >
                <input
                  name={@password_form[:email].name}
                  type="hidden"
                  id="hidden_settings_user_email"
                  autocomplete="username"
                  value={@current_email}
                />
                <.field
                  field={@password_form[:password]}
                  type="password"
                  label="New Password"
                  autocomplete="new-password"
                  required
                  no_margin
                />
                <.field
                  field={@password_form[:password_confirmation]}
                  type="password"
                  label="Confirm New Password"
                  autocomplete="new-password"
                  no_margin
                />
                <.button phx-disable-with="Saving..." class="w-full">Save Password</.button>
              </.form>
            </section>
          </div>
        </section>
      </div>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_settings_user_email(socket.assigns.current_scope.settings_user, token) do
        {:ok, _settings_user} ->
          put_flash(socket, :info, "Email changed successfully.")

        {:error, _} ->
          put_flash(socket, :error, "Email change link is invalid or it has expired.")
      end

    {:ok, push_navigate(socket, to: ~p"/settings_users/settings")}
  end

  def mount(_params, _session, socket) do
    settings_user = socket.assigns.current_scope.settings_user

    email_changeset =
      Accounts.change_settings_user_email(settings_user, %{}, validate_unique: false)

    password_changeset =
      Accounts.change_settings_user_password(settings_user, %{}, hash_password: false)

    socket =
      socket
      |> assign(:current_email, settings_user.email)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:trigger_submit, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_email", params, socket) do
    %{"settings_user" => settings_user_params} = params

    email_form =
      socket.assigns.current_scope.settings_user
      |> Accounts.change_settings_user_email(settings_user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", params, socket) do
    %{"settings_user" => settings_user_params} = params
    settings_user = socket.assigns.current_scope.settings_user
    true = Accounts.sudo_mode?(settings_user)

    case Accounts.change_settings_user_email(settings_user, settings_user_params) do
      %{valid?: true} = changeset ->
        Accounts.deliver_settings_user_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          settings_user.email,
          &url(~p"/settings_users/settings/confirm-email/#{&1}")
        )

        info = "A link to confirm your email change has been sent to the new address."
        {:noreply, socket |> put_flash(:info, info)}

      changeset ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"settings_user" => settings_user_params} = params

    password_form =
      socket.assigns.current_scope.settings_user
      |> Accounts.change_settings_user_password(settings_user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", params, socket) do
    %{"settings_user" => settings_user_params} = params
    settings_user = socket.assigns.current_scope.settings_user
    true = Accounts.sudo_mode?(settings_user)

    case Accounts.change_settings_user_password(settings_user, settings_user_params) do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end
end
