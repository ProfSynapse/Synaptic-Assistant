defmodule Assistant.Accounts.SettingsUserNotifier do
  import Swoosh.Email

  alias Assistant.Mailer
  alias Assistant.Accounts.SettingsUser

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from({"Assistant", "contact@example.com"})
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc """
  Deliver instructions to update a settings_user email.
  """
  def deliver_update_email_instructions(settings_user, url) do
    deliver(settings_user.email, "Update email instructions", """

    ==============================

    Hi #{settings_user.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(settings_user, url) do
    case settings_user do
      %SettingsUser{confirmed_at: nil} -> deliver_confirmation_instructions(settings_user, url)
      _ -> deliver_magic_link_instructions(settings_user, url)
    end
  end

  defp deliver_magic_link_instructions(settings_user, url) do
    deliver(settings_user.email, "Log in instructions", """

    ==============================

    Hi #{settings_user.email},

    You can log into your account by visiting the URL below:

    #{url}

    If you didn't request this email, please ignore this.

    ==============================
    """)
  end

  defp deliver_confirmation_instructions(settings_user, url) do
    deliver(settings_user.email, "Confirmation instructions", """

    ==============================

    Hi #{settings_user.email},

    You can confirm your account by visiting the URL below:

    #{url}

    If you didn't create an account with us, please ignore this.

    ==============================
    """)
  end
end
