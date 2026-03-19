defmodule Assistant.Mailer do
  @moduledoc false

  use Swoosh.Mailer, otp_app: :assistant

  def local_preview? do
    Application.get_env(:assistant, Assistant.Mailer)[:adapter] == Swoosh.Adapters.Local
  end

  def from_sender do
    {
      Application.get_env(:assistant, :mail_from_name, "Synaptic Assistant"),
      Application.get_env(:assistant, :mail_from_address, "contact@example.com")
    }
  end
end
