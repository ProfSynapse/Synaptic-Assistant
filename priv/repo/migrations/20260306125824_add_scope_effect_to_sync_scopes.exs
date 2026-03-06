defmodule Assistant.Repo.Migrations.AddScopeEffectToSyncScopes do
  use Ecto.Migration

  def change do
    alter table(:sync_scopes) do
      add :scope_effect, :string, null: false, default: "include"
    end

    execute(
      "ALTER TABLE sync_scopes ADD CONSTRAINT valid_scope_effect CHECK (scope_effect IN ('include', 'exclude'))",
      "ALTER TABLE sync_scopes DROP CONSTRAINT IF EXISTS valid_scope_effect"
    )
  end
end
