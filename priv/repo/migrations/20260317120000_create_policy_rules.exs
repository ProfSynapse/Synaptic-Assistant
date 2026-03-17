defmodule Assistant.Repo.Migrations.CreatePolicyRules do
  use Ecto.Migration

  def change do
    create table(:policy_rules, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :scope_type, :string, null: false, default: "system"
      add :scope_id, :binary_id
      add :resource_type, :string, null: false
      add :effect, :string, null: false
      add :matchers, :map, default: %{}
      add :priority, :integer, null: false, default: 100
      add :enabled, :boolean, null: false, default: true
      add :reason, :string
      add :source, :string, null: false, default: "system_default"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:policy_rules, [:scope_type, :scope_id])
    create index(:policy_rules, [:resource_type, :effect])
    create index(:policy_rules, [:priority])
  end
end
