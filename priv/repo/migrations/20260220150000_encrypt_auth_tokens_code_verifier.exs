defmodule Assistant.Repo.Migrations.EncryptAuthTokensCodeVerifier do
  use Ecto.Migration

  def change do
    alter table(:auth_tokens) do
      remove :code_verifier, :string
      add :code_verifier, :binary
    end
  end
end
