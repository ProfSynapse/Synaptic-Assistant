defmodule Assistant.Billing.Metering do
  @moduledoc """
  Tenant storage metering helpers for billing.

  The main billing flow uses this module to measure retained bytes at the
  billing-account level, prepare snapshot payloads, and compute average
  overage from hourly snapshots.
  """

  import Ecto.Query, warn: false
  require Assistant.Billing.StorageAccounting

  alias Assistant.Billing.{AccountFacts, StorageAccounting}
  alias Assistant.Repo

  alias Assistant.Schemas.{
    BillingAccount,
    BillingUsageSnapshot,
    MemoryEntry,
    Message,
    SyncedFile
  }

  @type usage_breakdown :: %{
          billing_account_id: binary(),
          plan: String.t(),
          seat_count: non_neg_integer(),
          included_bytes: non_neg_integer(),
          synced_file_bytes: non_neg_integer(),
          message_bytes: non_neg_integer(),
          memory_bytes: non_neg_integer(),
          total_bytes: non_neg_integer(),
          overage_bytes: non_neg_integer(),
          overage_units: non_neg_integer()
        }

  @spec current_usage(binary() | BillingAccount.t()) ::
          {:ok, usage_breakdown()} | {:error, :not_found | :invalid_billing_account_id}
  def current_usage(%BillingAccount{id: billing_account_id}),
    do: current_usage(billing_account_id)

  def current_usage(billing_account_id)
      when is_binary(billing_account_id) and billing_account_id != "" do
    case usage_breakdown(billing_account_id) do
      {:ok, breakdown} -> {:ok, breakdown}
      {:error, _reason} = error -> error
    end
  end

  def current_usage(_), do: {:error, :invalid_billing_account_id}

  @spec snapshot_attrs(binary() | BillingAccount.t(), DateTime.t()) ::
          {:ok, map()} | {:error, :not_found | :invalid_billing_account_id}
  def snapshot_attrs(billing_account_or_id, measured_at \\ DateTime.utc_now())

  def snapshot_attrs(%BillingAccount{} = billing_account, measured_at) do
    snapshot_attrs(billing_account.id, measured_at)
  end

  def snapshot_attrs(billing_account_id, measured_at)
      when is_binary(billing_account_id) and billing_account_id != "" and
             is_struct(measured_at, DateTime) do
    with {:ok, usage} <- current_usage(billing_account_id) do
      {:ok,
       Map.merge(usage, %{
         measured_at: measured_at
       })}
    end
  end

  def snapshot_attrs(_billing_account_id, _measured_at),
    do: {:error, :invalid_billing_account_id}

  @spec average_overage_bytes(binary() | BillingAccount.t(), DateTime.t(), DateTime.t()) ::
          non_neg_integer()
  def average_overage_bytes(%BillingAccount{id: billing_account_id}, period_start, period_end) do
    average_overage_bytes(billing_account_id, period_start, period_end)
  end

  def average_overage_bytes(billing_account_id, period_start, period_end)
      when is_binary(billing_account_id) and billing_account_id != "" and
             is_struct(period_start, DateTime) and is_struct(period_end, DateTime) do
    overage_bytes =
      Repo.all(
        from s in BillingUsageSnapshot,
          where: s.billing_account_id == ^billing_account_id,
          where: s.measured_at >= ^period_start and s.measured_at < ^period_end,
          select: s.overage_bytes
      )

    case overage_bytes do
      [] -> 0
      values -> div(Enum.sum(values), length(values))
    end
  end

  def average_overage_bytes(_, _, _), do: 0

  @spec average_overage_units(binary() | BillingAccount.t(), DateTime.t(), DateTime.t()) ::
          non_neg_integer()
  def average_overage_units(billing_account_id, period_start, period_end) do
    billing_account_id
    |> average_overage_bytes(period_start, period_end)
    |> bytes_to_overage_units()
  end

  @spec bytes_to_overage_units(non_neg_integer()) :: non_neg_integer()
  def bytes_to_overage_units(bytes) when is_integer(bytes) and bytes <= 0, do: 0

  def bytes_to_overage_units(bytes) when is_integer(bytes) do
    unit_bytes = AccountFacts.storage_overage_unit_bytes()
    div(bytes + unit_bytes - 1, unit_bytes)
  end

  @spec included_bytes_for_account(binary() | BillingAccount.t()) :: non_neg_integer()
  def included_bytes_for_account(%BillingAccount{} = billing_account) do
    included_bytes_for_account(billing_account.id)
  end

  def included_bytes_for_account(billing_account_id) when is_binary(billing_account_id) do
    case Repo.get(BillingAccount, billing_account_id) do
      %BillingAccount{} = billing_account ->
        billing_account |> AccountFacts.from_account() |> Map.fetch!(:included_bytes)

      nil ->
        0
    end
  end

  def included_bytes_for_account(_), do: 0

  @doc false
  @spec stripe_overage_unit_bytes() :: pos_integer()
  def stripe_overage_unit_bytes, do: AccountFacts.storage_overage_unit_bytes()

  defp usage_breakdown(billing_account_id) do
    with %BillingAccount{} = billing_account <- Repo.get(BillingAccount, billing_account_id) do
      facts = AccountFacts.from_account(billing_account)

      synced_file_bytes = synced_file_bytes(billing_account_id)
      message_bytes = message_bytes(billing_account_id)
      memory_bytes = memory_bytes(billing_account_id)
      total_bytes = synced_file_bytes + message_bytes + memory_bytes
      overage_bytes = max(total_bytes - facts.included_bytes, 0)

      {:ok,
       %{
         billing_account_id: billing_account.id,
         plan: facts.plan,
         seat_count: facts.seat_count,
         included_bytes: facts.included_bytes,
         synced_file_bytes: synced_file_bytes,
         message_bytes: message_bytes,
         memory_bytes: memory_bytes,
         total_bytes: total_bytes,
         overage_bytes: overage_bytes,
         overage_units: bytes_to_overage_units(overage_bytes)
       }}
    else
      nil -> {:error, :not_found}
    end
  end

  defp synced_file_bytes(billing_account_id) do
    Repo.all(
      from sf in SyncedFile,
        join: u in assoc(sf, :user),
        where: u.billing_account_id == ^billing_account_id,
        where: not is_nil(sf.content),
        select: sf.content
    )
    |> Enum.reduce(0, fn content, acc ->
      acc + StorageAccounting.synced_file_growth(nil, content)
    end)
  end

  defp message_bytes(billing_account_id) do
    billing_account_id
    |> message_bytes_query()
    |> Repo.all()
    |> Enum.map(&normalize_byte_total/1)
    |> Enum.sum()
  end

  defp message_bytes_query(billing_account_id) do
    from m in Message,
      join: c in assoc(m, :conversation),
      join: u in assoc(c, :user),
      where: u.billing_account_id == ^billing_account_id,
      select:
        type(
          StorageAccounting.message_size_expr(
            m.content_encrypted,
            m.tool_calls,
            m.tool_results
          ),
          :integer
        )
  end

  defp memory_bytes(billing_account_id) do
    billing_account_id
    |> memory_bytes_query()
    |> Repo.all()
    |> Enum.map(&normalize_byte_total/1)
    |> Enum.sum()
  end

  defp memory_bytes_query(billing_account_id) do
    from me in MemoryEntry,
      join: u in assoc(me, :user),
      where: u.billing_account_id == ^billing_account_id,
      select: type(StorageAccounting.memory_entry_size_expr(me.title, me.content_encrypted), :integer)
  end

  defp normalize_byte_total(%Decimal{} = value), do: Decimal.to_integer(value)
  defp normalize_byte_total(value) when is_integer(value), do: value
  defp normalize_byte_total(_), do: 0
end
