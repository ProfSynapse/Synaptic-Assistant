defmodule Assistant.Repo.Migrations.CreateIntegrationSettings do
  @moduledoc """
  Creates the integration_settings table for admin-configurable API keys and tokens.

  Values are encrypted at rest via Cloak AES-GCM (stored as :binary / BYTEA).
  Row-level security provides defense-in-depth — queries outside an admin
  transaction silently return no rows.
  """
  use Ecto.Migration

  def change do
    create table(:integration_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :key, :text, null: false
      add :value, :binary
      add :group, :text, null: false

      add :updated_by_id, references(:settings_users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:integration_settings, [:key])
    create index(:integration_settings, [:group])

    # Row-level security as defense-in-depth.
    # The context module sets `SET LOCAL app.is_admin = 'true'` inside transactions.
    # The `true` second arg to current_setting makes it return '' instead of raising
    # when the variable is not set (missing_ok).
    execute(
      "ALTER TABLE integration_settings ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE integration_settings DISABLE ROW LEVEL SECURITY"
    )

    # FORCE ensures RLS applies even to the table owner (the app's DB user).
    # Without this, the owner bypasses all policies and SET LOCAL has no effect.
    execute(
      "ALTER TABLE integration_settings FORCE ROW LEVEL SECURITY",
      "ALTER TABLE integration_settings NO FORCE ROW LEVEL SECURITY"
    )

    execute(
      """
      CREATE POLICY admin_read ON integration_settings FOR SELECT
        USING (current_setting('app.is_admin', true) = 'true')
      """,
      "DROP POLICY IF EXISTS admin_read ON integration_settings"
    )

    execute(
      """
      CREATE POLICY admin_write ON integration_settings FOR ALL
        USING (current_setting('app.is_admin', true) = 'true')
      """,
      "DROP POLICY IF EXISTS admin_write ON integration_settings"
    )
  end
end
