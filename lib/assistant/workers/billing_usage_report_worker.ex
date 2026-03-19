defmodule Assistant.Workers.BillingUsageReportWorker do
  @moduledoc """
  Reports the current-period average storage overage for each billing account.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1

  alias Assistant.Billing

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    as_of = DateTime.utc_now() |> DateTime.truncate(:second)

    case run_for_accounts(Billing.list_billing_accounts(), fn billing_account ->
           Billing.report_overage_to_stripe(billing_account, as_of: as_of)
         end) do
      :ok ->
        :ok

      {:error, failures} ->
        Logger.warning("BillingUsageReportWorker failed", failures: inspect(failures))
        {:error, {:report_failed, failures}}
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
            {:error, :skip} -> :ok
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
end
