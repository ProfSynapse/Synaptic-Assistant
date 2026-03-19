defmodule Assistant.Billing.Policy do
  @moduledoc """
  Storage policy checks for retained writes.
  """

  alias Assistant.Billing
  alias Assistant.Billing.StorageAccounting
  alias Assistant.Repo
  alias Assistant.Schemas.{BillingAccount, User}

  @type storage_limit_error :: {:storage_limit_exceeded, map()}

  @spec ensure_retained_write_allowed(binary() | nil, integer()) ::
          :ok | {:error, storage_limit_error()}
  def ensure_retained_write_allowed(_user_id, growth_bytes)
      when not is_integer(growth_bytes) or growth_bytes <= 0 do
    :ok
  end

  def ensure_retained_write_allowed(user_id, growth_bytes) when is_binary(user_id) do
    with %User{billing_account_id: billing_account_id}
         when is_binary(billing_account_id) and billing_account_id != "" <-
           Repo.get(User, user_id),
         %BillingAccount{} = billing_account <- Repo.get(BillingAccount, billing_account_id),
         %{plan: "free", hard_limit_bytes: hard_limit_bytes} <-
           Billing.storage_policy(billing_account),
         {:ok, usage} <- Billing.current_storage_usage(billing_account) do
      projected_bytes = usage.total_bytes + growth_bytes

      if projected_bytes > hard_limit_bytes do
        {:error,
         {:storage_limit_exceeded,
          %{
            plan: "free",
            included_bytes: hard_limit_bytes,
            current_bytes: usage.total_bytes,
            growth_bytes: growth_bytes,
            projected_bytes: projected_bytes
          }}}
      else
        :ok
      end
    else
      %BillingAccount{} ->
        :ok

      _ ->
        :ok
    end
  end

  def ensure_retained_write_allowed(_user_id, _growth_bytes), do: :ok

  @spec synced_file_growth(binary() | nil, binary() | nil) :: non_neg_integer()
  def synced_file_growth(existing_content, new_content) do
    StorageAccounting.synced_file_growth(existing_content, new_content)
  end

  @spec message_retained_bytes(map()) :: non_neg_integer()
  def message_retained_bytes(attrs) when is_map(attrs),
    do: StorageAccounting.message_retained_bytes(attrs)

  @spec memory_entry_retained_bytes(map()) :: non_neg_integer()
  def memory_entry_retained_bytes(attrs) when is_map(attrs),
    do: StorageAccounting.memory_entry_retained_bytes(attrs)

  @spec memory_entry_growth(struct(), map()) :: non_neg_integer()
  def memory_entry_growth(existing, attrs) when is_map(attrs),
    do: StorageAccounting.memory_entry_growth(existing, attrs)
end
