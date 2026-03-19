defmodule Assistant.Workers.BillingUsageSnapshotWorker do
  @moduledoc """
  Captures hourly retained-storage snapshots for each billing account.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1

  alias Assistant.Billing

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    measured_at = current_hour()

    case run_for_accounts(Billing.list_billing_accounts(), fn billing_account ->
           Billing.record_usage_snapshot(billing_account, measured_at)
         end) do
      :ok ->
        :ok

      {:error, failures} ->
        Logger.warning("BillingUsageSnapshotWorker failed", failures: inspect(failures))
        {:error, {:snapshot_failed, failures}}
    end
  end

  defp run_for_accounts([], _fun), do: :ok

  defp run_for_accounts(accounts, fun) do
    failures =
      accounts
      |> Task.async_stream(
        fn billing_account ->
          case fun.(billing_account) do
            {:ok, _result} -> :ok
            :ok -> :ok
            {:error, reason} -> {:error, {billing_account.id, reason}}
          end
        end,
        timeout: :infinity
      )
      |> Enum.reduce([], fn
        {:ok, :ok}, failures ->
          failures

        {:ok, {:error, failure}}, failures ->
          [failure | failures]

        {:exit, reason}, failures ->
          [{:task_exit, reason} | failures]
      end)
      |> Enum.reverse()

    case failures do
      [] -> :ok
      failures -> {:error, failures}
    end
  end

  defp current_hour do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> Map.put(:minute, 0)
    |> Map.put(:second, 0)
  end
end
