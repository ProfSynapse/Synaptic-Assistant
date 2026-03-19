defmodule Assistant.Repo.Migrations.AddVaultTransitStageE1ExecutionLogs do
  use Ecto.Migration

  def change do
    alter table(:execution_logs) do
      add :billing_account_id, references(:billing_accounts, on_delete: :nothing, type: :binary_id)
      add :parameters_encrypted, :map
      add :result_encrypted, :map
      add :error_message_encrypted, :map
    end

    create index(:execution_logs, [:billing_account_id])
  end
end
