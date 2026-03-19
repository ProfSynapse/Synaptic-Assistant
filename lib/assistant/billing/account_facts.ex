defmodule Assistant.Billing.AccountFacts do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Assistant.Accounts.SettingsUser
  alias Assistant.Repo
  alias Assistant.Schemas.BillingAccount

  @active_subscription_statuses ~w(active trialing past_due)
  @free_storage_limit_bytes 25_000_000
  @pro_storage_included_bytes_per_seat 10_000_000_000
  @storage_overage_unit_bytes 1_000_000_000
  @storage_overage_unit_price_cents 100

  @type t :: %{
          account_id: binary() | nil,
          account_name: binary() | nil,
          plan: String.t(),
          billing_mode: String.t(),
          stripe_subscription_status: String.t() | nil,
          seat_count: non_neg_integer(),
          seat_bonus: non_neg_integer(),
          storage_bonus_bytes: non_neg_integer(),
          billing_email: String.t() | nil,
          current_period_end: DateTime.t() | nil,
          complimentary_until: DateTime.t() | nil,
          included_bytes: non_neg_integer(),
          hard_limit_bytes: non_neg_integer() | nil,
          overage_allowed?: boolean(),
          overage_unit_bytes: pos_integer(),
          overage_unit_price_cents: pos_integer()
        }

  def free_storage_limit_bytes, do: @free_storage_limit_bytes
  def pro_storage_included_bytes_per_seat, do: @pro_storage_included_bytes_per_seat
  def storage_overage_unit_bytes, do: @storage_overage_unit_bytes
  def storage_overage_unit_price_cents, do: @storage_overage_unit_price_cents

  def default do
    %{
      account_id: nil,
      account_name: nil,
      plan: "free",
      billing_mode: "standard",
      stripe_subscription_status: nil,
      seat_count: 0,
      seat_bonus: 0,
      storage_bonus_bytes: 0,
      billing_email: nil,
      current_period_end: nil,
      complimentary_until: nil,
      included_bytes: @free_storage_limit_bytes,
      hard_limit_bytes: @free_storage_limit_bytes,
      overage_allowed?: false,
      overage_unit_bytes: @storage_overage_unit_bytes,
      overage_unit_price_cents: @storage_overage_unit_price_cents
    }
  end

  def from_account(billing_account, opts \\ [])

  def from_account(nil, _opts), do: default()

  def from_account(%BillingAccount{} = billing_account, opts) do
    as_of = Keyword.get(opts, :as_of, DateTime.utc_now())
    seat_count = Keyword.get_lazy(opts, :seat_count, fn -> seat_count(billing_account.id) end)
    billing_mode = effective_billing_mode(billing_account, as_of)
    plan = effective_plan(billing_account, billing_mode)
    seat_bonus = max(billing_account.seat_bonus || 0, 0)
    storage_bonus_bytes = max(billing_account.storage_bonus_bytes || 0, 0)

    %{
      account_id: billing_account.id,
      account_name: billing_account.name,
      plan: plan,
      billing_mode: billing_mode,
      stripe_subscription_status: billing_account.stripe_subscription_status,
      seat_count: seat_count,
      seat_bonus: seat_bonus,
      storage_bonus_bytes: storage_bonus_bytes,
      billing_email: billing_account.billing_email,
      current_period_end: billing_account.stripe_current_period_end,
      complimentary_until: billing_account.complimentary_until,
      included_bytes: included_storage_bytes(plan, seat_count, seat_bonus, storage_bonus_bytes),
      hard_limit_bytes: hard_limit_bytes(plan, storage_bonus_bytes),
      overage_allowed?: overage_allowed?(plan),
      overage_unit_bytes: @storage_overage_unit_bytes,
      overage_unit_price_cents: @storage_overage_unit_price_cents
    }
  end

  def billing_summary(%{} = facts, opts \\ []) do
    %{
      account_id: facts.account_id,
      account_name: facts.account_name,
      plan: facts.plan,
      billing_mode: facts.billing_mode,
      stripe_subscription_status: facts.stripe_subscription_status,
      seat_count: facts.seat_count,
      seat_bonus: facts.seat_bonus,
      storage_bonus_bytes: facts.storage_bonus_bytes,
      billing_email: facts.billing_email || Keyword.get(opts, :billing_email),
      current_period_end: facts.current_period_end,
      complimentary_until: facts.complimentary_until,
      can_manage?: Keyword.get(opts, :can_manage?, false)
    }
  end

  def storage_policy(%{} = facts) do
    %{
      plan: facts.plan,
      billing_mode: facts.billing_mode,
      seat_count: facts.seat_count,
      seat_bonus: facts.seat_bonus,
      storage_bonus_bytes: facts.storage_bonus_bytes,
      included_bytes: facts.included_bytes,
      hard_limit_bytes: facts.hard_limit_bytes,
      overage_allowed?: facts.overage_allowed?,
      overage_unit_bytes: facts.overage_unit_bytes,
      overage_unit_price_cents: facts.overage_unit_price_cents,
      complimentary_until: facts.complimentary_until
    }
  end

  def override_form(nil) do
    %{
      "plan" => "free",
      "billing_mode" => "standard",
      "complimentary_until" => "",
      "seat_bonus" => 0,
      "storage_bonus_gb" => 0,
      "internal_notes" => ""
    }
  end

  def override_form(%BillingAccount{} = billing_account) do
    %{
      "plan" => billing_account.plan || "free",
      "billing_mode" => billing_account.billing_mode || "standard",
      "complimentary_until" => iso8601_or_blank(billing_account.complimentary_until),
      "seat_bonus" => max(billing_account.seat_bonus || 0, 0),
      "storage_bonus_gb" =>
        Integer.floor_div(
          max(billing_account.storage_bonus_bytes || 0, 0),
          @storage_overage_unit_bytes
        ),
      "internal_notes" => billing_account.internal_notes || ""
    }
  end

  def seat_count(billing_account_id) when is_binary(billing_account_id) do
    Repo.one(
      from(su in SettingsUser,
        where: su.billing_account_id == ^billing_account_id and is_nil(su.disabled_at),
        select: count(su.id)
      )
    ) || 0
  end

  def seat_count(_), do: 0

  def active_subscription_status?(status), do: status in @active_subscription_statuses

  def active_or_pending_subscription_status?(status),
    do: active_subscription_status?(status) or status == "pending_activation"

  def effective_billing_mode(%BillingAccount{} = billing_account, as_of \\ DateTime.utc_now()) do
    case billing_account.billing_mode || "standard" do
      "complimentary" ->
        if complimentary_active?(billing_account.complimentary_until, as_of) do
          "complimentary"
        else
          "standard"
        end

      mode ->
        mode
    end
  end

  def effective_plan(%BillingAccount{} = billing_account, billing_mode \\ nil) do
    billing_mode = billing_mode || effective_billing_mode(billing_account)

    case billing_mode do
      mode when mode in ["complimentary", "manual"] ->
        billing_account.plan || "free"

      _standard ->
        if active_or_pending_subscription_status?(billing_account.stripe_subscription_status) do
          "pro"
        else
          "free"
        end
    end
  end

  def included_storage_bytes("pro", seat_count, seat_bonus, storage_bonus_bytes) do
    max(seat_count + seat_bonus, 0) * @pro_storage_included_bytes_per_seat + storage_bonus_bytes
  end

  def included_storage_bytes(_plan, _seat_count, _seat_bonus, storage_bonus_bytes) do
    @free_storage_limit_bytes + storage_bonus_bytes
  end

  def hard_limit_bytes("free", storage_bonus_bytes),
    do: @free_storage_limit_bytes + storage_bonus_bytes

  def hard_limit_bytes(_plan, _storage_bonus_bytes), do: nil

  def overage_allowed?("pro"), do: true
  def overage_allowed?(_plan), do: false

  defp complimentary_active?(nil, _as_of), do: true

  defp complimentary_active?(%DateTime{} = complimentary_until, %DateTime{} = as_of) do
    DateTime.compare(complimentary_until, as_of) == :gt
  end

  defp complimentary_active?(_, _as_of), do: false

  defp iso8601_or_blank(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601_or_blank(_), do: ""
end
