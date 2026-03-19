defmodule Assistant.Repo.Migrations.CreateContentTerms do
  use Ecto.Migration

  def change do
    create table(:content_terms, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :billing_account_id, :binary_id, null: false
      add :owner_type, :string, null: false
      add :owner_id, :binary_id, null: false
      add :field, :string, null: false
      add :term_digest, :string, null: false
      add :term_frequency, :integer, default: 1, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:content_terms, [:billing_account_id, :owner_type, :field, :term_digest])
    create index(:content_terms, [:owner_id])
  end
end
