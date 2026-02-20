defmodule Assistant.Repo.Migrations.EncryptAuthTokensCodeVerifier do
  @moduledoc """
  Migrates auth_tokens for our branch's requirements:
  1. Converts code_verifier from :text to :binary (Cloak encryption at rest)
  2. Adds pending_intent :binary (stores the user's original command for replay)
  """
  use Ecto.Migration

  def change do
    alter table(:auth_tokens) do
      remove :code_verifier, :text
      add :code_verifier, :binary
      add :pending_intent, :binary
    end
  end
end
