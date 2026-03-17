defmodule Assistant.Repo.Migrations.CreatePolicyApprovals do
  use Ecto.Migration

  def change do
    create table(:policy_approvals, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :binary_id
      add :workspace_id, :binary_id
      add :rule_id, references(:policy_rules, on_delete: :nilify_all, type: :binary_id)
      add :resource_type, :string, null: false
      add :effect, :string, null: false
      add :request_fingerprint, :string
      add :metadata, :map, default: %{}
      add :expires_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:policy_approvals, [:user_id])
    create index(:policy_approvals, [:workspace_id])
    create index(:policy_approvals, [:resource_type, :effect])
  end
end
