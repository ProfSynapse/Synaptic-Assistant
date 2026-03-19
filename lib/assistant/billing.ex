defmodule Assistant.Billing do
  @moduledoc """
  Billing account management and Stripe integration.
  """

  import Ecto.Query, warn: false

  alias Assistant.Accounts.SettingsUser
  alias Assistant.Billing.{AccountFacts, Metering, StripeClient}
  alias Assistant.Repo
  alias Assistant.Schemas.{BillingAccount, BillingUsageReport, BillingUsageSnapshot, User}

  @manageable_roles ~w(owner admin)
  @type billing_summary :: %{
          account_id: String.t() | nil,
          account_name: String.t() | nil,
          plan: String.t(),
          billing_mode: String.t(),
          stripe_subscription_status: String.t() | nil,
          seat_count: non_neg_integer(),
          seat_bonus: non_neg_integer(),
          storage_bonus_bytes: non_neg_integer(),
          billing_email: String.t() | nil,
          current_period_end: DateTime.t() | nil,
          complimentary_until: DateTime.t() | nil,
          can_manage?: boolean()
        }

  @type storage_policy :: %{
          plan: String.t(),
          billing_mode: String.t(),
          seat_count: non_neg_integer(),
          seat_bonus: non_neg_integer(),
          storage_bonus_bytes: non_neg_integer(),
          included_bytes: non_neg_integer(),
          hard_limit_bytes: non_neg_integer() | nil,
          overage_allowed?: boolean(),
          overage_unit_bytes: pos_integer(),
          overage_unit_price_cents: pos_integer(),
          complimentary_until: DateTime.t() | nil
        }

  def manages_billing?(%SettingsUser{} = settings_user) do
    settings_user.is_admin == true or settings_user.billing_role in @manageable_roles
  end

  def manages_billing?(_), do: false

  @type billing_snapshot :: %{
          settings_user: SettingsUser.t() | nil,
          billing_account: BillingAccount.t() | nil,
          account_facts: AccountFacts.t(),
          billing_summary: billing_summary(),
          storage_policy: storage_policy()
        }

  @doc """
  Ensures the settings user belongs to a billing account.
  """
  @spec ensure_billing_account(%SettingsUser{}) ::
          {:ok, {%SettingsUser{}, %BillingAccount{}}} | {:error, term()}
  def ensure_billing_account(%SettingsUser{id: settings_user_id})
      when is_binary(settings_user_id) do
    Repo.transact(fn ->
      settings_user =
        SettingsUser
        |> Repo.get!(settings_user_id)
        |> Repo.preload(:billing_account)

      case settings_user.billing_account do
        %BillingAccount{} = billing_account ->
          {:ok, {settings_user, billing_account}}

        nil ->
          attrs = %{
            name: default_account_name(settings_user),
            billing_email: settings_user.email,
            plan: "free"
          }

          with {:ok, billing_account} <-
                 %BillingAccount{}
                 |> BillingAccount.changeset(attrs)
                 |> Repo.insert(),
               {:ok, updated_settings_user} <-
                 settings_user
                 |> SettingsUser.billing_membership_changeset(billing_account.id, "owner")
                 |> Repo.update() do
            :ok = sync_linked_user_billing_account(updated_settings_user)
            {:ok, {updated_settings_user, billing_account}}
          else
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
  end

  @doc """
  Assigns a settings user to an existing billing account.
  """
  def assign_settings_user_to_account(
        %SettingsUser{} = settings_user,
        %BillingAccount{} = billing_account,
        role \\ "member"
      ) do
    settings_user
    |> SettingsUser.billing_membership_changeset(billing_account.id, role)
    |> Repo.update()
    |> case do
      {:ok, updated_settings_user} ->
        :ok = sync_linked_user_billing_account(updated_settings_user)
        {:ok, updated_settings_user}

      error ->
        error
    end
  end

  def free_storage_limit_bytes, do: AccountFacts.free_storage_limit_bytes()

  def pro_storage_included_bytes_per_seat, do: AccountFacts.pro_storage_included_bytes_per_seat()

  def storage_overage_unit_bytes, do: AccountFacts.storage_overage_unit_bytes()

  def storage_overage_unit_price_cents, do: AccountFacts.storage_overage_unit_price_cents()

  def billing_snapshot(settings_user, opts \\ [])

  def billing_snapshot(nil, _opts) do
    facts = AccountFacts.default()

    %{
      settings_user: nil,
      billing_account: nil,
      account_facts: facts,
      billing_summary: AccountFacts.billing_summary(facts),
      storage_policy: AccountFacts.storage_policy(facts)
    }
  end

  def billing_snapshot(%SettingsUser{} = settings_user, opts) do
    can_manage? = Keyword.get(opts, :can_manage?, manages_billing?(settings_user))

    case load_settings_user_billing_account(settings_user, opts) do
      {:ok, {resolved_settings_user, billing_account}} ->
        facts = AccountFacts.from_account(billing_account)

        %{
          settings_user: resolved_settings_user,
          billing_account: billing_account,
          account_facts: facts,
          billing_summary:
            AccountFacts.billing_summary(facts,
              billing_email: resolved_settings_user.email,
              can_manage?: can_manage?
            ),
          storage_policy: AccountFacts.storage_policy(facts)
        }

      {:error, _reason} ->
        facts = AccountFacts.default()

        %{
          settings_user: settings_user,
          billing_account: nil,
          account_facts: facts,
          billing_summary:
            AccountFacts.billing_summary(facts,
              billing_email: settings_user.email,
              can_manage?: can_manage?
            ),
          storage_policy: AccountFacts.storage_policy(facts)
        }
    end
  end

  def billing_override_form(billing_account), do: AccountFacts.override_form(billing_account)

  @doc """
  Returns a billing summary suitable for the settings UI.
  """
  @spec billing_summary(%SettingsUser{} | nil) :: billing_summary()
  def billing_summary(nil), do: AccountFacts.default() |> AccountFacts.billing_summary()

  def billing_summary(%SettingsUser{} = settings_user) do
    settings_user
    |> billing_snapshot(ensure?: true)
    |> Map.fetch!(:billing_summary)
  end

  def billing_summary_for_account(billing_account, opts \\ [])

  def billing_summary_for_account(nil, _opts), do: billing_summary(nil)

  def billing_summary_for_account(%BillingAccount{} = billing_account, opts) do
    billing_account
    |> AccountFacts.from_account()
    |> AccountFacts.billing_summary(opts)
  end

  @doc """
  Returns the tenant storage policy for a settings user or billing account.
  """
  @spec storage_policy(%SettingsUser{} | %BillingAccount{} | nil) :: storage_policy()
  def storage_policy(nil), do: AccountFacts.default() |> AccountFacts.storage_policy()

  def storage_policy(%SettingsUser{} = settings_user) do
    settings_user
    |> billing_snapshot(ensure?: true)
    |> Map.fetch!(:storage_policy)
  end

  def storage_policy(%BillingAccount{} = billing_account) do
    billing_account
    |> AccountFacts.from_account()
    |> AccountFacts.storage_policy()
  end

  def included_storage_bytes(%SettingsUser{} = settings_user) do
    settings_user
    |> storage_policy()
    |> Map.fetch!(:included_bytes)
  end

  def included_storage_bytes(%BillingAccount{} = billing_account) do
    billing_account
    |> storage_policy()
    |> Map.fetch!(:included_bytes)
  end

  def current_storage_usage(%SettingsUser{} = settings_user) do
    with {:ok, {_, billing_account}} <-
           load_settings_user_billing_account(settings_user, ensure?: true),
         %BillingAccount{} = billing_account <- billing_account do
      current_storage_usage(billing_account)
    else
      _ -> {:error, :not_found}
    end
  end

  def current_storage_usage(%BillingAccount{} = billing_account),
    do: Metering.current_usage(billing_account)

  def record_usage_snapshot(
        %BillingAccount{} = billing_account,
        measured_at \\ DateTime.utc_now()
      ) do
    with {:ok, attrs} <- Metering.snapshot_attrs(billing_account, measured_at),
         {:ok, snapshot} <- upsert_usage_snapshot(attrs) do
      {:ok, snapshot}
    end
  end

  def projected_storage_overage(%BillingAccount{} = billing_account, opts \\ []) do
    as_of =
      Keyword.get(opts, :as_of, DateTime.utc_now())
      |> DateTime.truncate(:second)

    {period_start, period_end} = current_billing_period(as_of)

    current_overage_bytes =
      case Metering.current_usage(billing_account) do
        {:ok, usage} -> usage.overage_bytes
        _ -> 0
      end

    average_overage_bytes =
      case snapshot_count(billing_account.id, period_start, period_end) do
        0 ->
          current_overage_bytes

        _count ->
          Metering.average_overage_bytes(billing_account, period_start, period_end)
      end

    projected_overage_units = Metering.bytes_to_overage_units(average_overage_bytes)

    {:ok,
     %{
       period_start: period_start,
       period_end: period_end,
       projected_overage_bytes: average_overage_bytes,
       projected_overage_units: projected_overage_units,
       projected_overage_cents: projected_overage_units * storage_overage_unit_price_cents()
     }}
  end

  def report_overage_to_stripe(%BillingAccount{} = billing_account, opts \\ []) do
    as_of =
      Keyword.get(opts, :as_of, DateTime.utc_now())
      |> DateTime.truncate(:second)

    with :ok <- reportable_billing_account(billing_account),
         {:ok, meter_event_name} <- storage_meter_event_name(),
         {:ok, projection} <- projected_storage_overage(billing_account, as_of: as_of),
         identifier <- meter_event_identifier(billing_account.id, as_of),
         {:ok, _response} <-
           StripeClient.create_meter_event(%{
             event_name: meter_event_name,
             identifier: identifier,
             timestamp: DateTime.to_unix(as_of),
             payload: %{
               stripe_customer_id: billing_account.stripe_customer_id,
               value: projection.projected_overage_units
             }
           }),
         {:ok, report} <- upsert_usage_report(billing_account, projection, identifier, as_of) do
      {:ok, report}
    end
  end

  def list_billing_accounts do
    Repo.all(from account in BillingAccount, order_by: [asc: account.inserted_at])
  end

  @doc """
  Updates workspace-level billing overrides for internal exceptions and comps.
  """
  def update_billing_account_overrides(billing_account_id, attrs)
      when is_binary(billing_account_id) and is_map(attrs) do
    case Repo.get(BillingAccount, billing_account_id) do
      nil ->
        {:error, :not_found}

      %BillingAccount{} = billing_account ->
        with {:ok, normalized_attrs} <- normalize_billing_override_attrs(billing_account, attrs) do
          billing_account
          |> BillingAccount.changeset(normalized_attrs)
          |> Repo.update()
        end
    end
  end

  @doc """
  Syncs the linked chat user's billing account from settings-user membership.
  """
  def sync_linked_user_billing_account(%SettingsUser{user_id: user_id})
      when is_binary(user_id) and user_id != "" do
    sync_linked_user_billing_account_by_user_id(user_id)
  end

  def sync_linked_user_billing_account(_), do: :ok

  def sync_linked_user_billing_account_by_user_id(user_id)
      when is_binary(user_id) and user_id != "" do
    billing_account_id =
      Repo.one(
        from(su in SettingsUser,
          where: su.user_id == ^user_id,
          where: is_nil(su.disabled_at),
          where: not is_nil(su.billing_account_id),
          order_by: [asc: su.inserted_at],
          select: su.billing_account_id,
          limit: 1
        )
      )

    from(u in User, where: u.id == ^user_id)
    |> Repo.update_all(set: [billing_account_id: billing_account_id])

    :ok
  end

  def sync_linked_user_billing_account_by_user_id(_), do: :ok

  @doc """
  Creates a Stripe Checkout session for the shared Pro plan.
  """
  def create_checkout_session(%SettingsUser{} = settings_user) do
    with true <- manages_billing?(settings_user) or {:error, :forbidden},
         {:ok, {_, billing_account}} <- ensure_billing_account(settings_user),
         {:ok, billing_account} <- ensure_stripe_customer(billing_account),
         :ok <- ensure_checkout_ready(billing_account),
         {:ok, price_id} <- pro_price_id(),
         {:ok, response} <-
           StripeClient.create_checkout_session(%{
             mode: "subscription",
             success_url: success_url(),
             cancel_url: cancel_url(),
             customer: billing_account.stripe_customer_id,
             client_reference_id: billing_account.id,
             allow_promotion_codes: true,
             metadata: %{
               billing_account_id: billing_account.id
             },
             subscription_data: %{
               metadata: %{
                 billing_account_id: billing_account.id
               }
             },
             line_items: [
               %{
                 price: price_id,
                 quantity: seat_count(billing_account.id)
               }
             ]
           }),
         url when is_binary(url) <- Map.get(response, "url") do
      {:ok, url}
    else
      false -> {:error, :forbidden}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_checkout_response}
    end
  end

  @doc """
  Creates a Stripe billing portal session for the billing account.
  """
  def create_portal_session(%SettingsUser{} = settings_user) do
    with true <- manages_billing?(settings_user) or {:error, :forbidden},
         {:ok, {_, billing_account}} <- ensure_billing_account(settings_user),
         {:ok, billing_account} <- ensure_stripe_customer(billing_account),
         {:ok, response} <-
           StripeClient.create_portal_session(%{
             customer: billing_account.stripe_customer_id,
             return_url: return_url()
           }),
         url when is_binary(url) <- Map.get(response, "url") do
      {:ok, url}
    else
      false -> {:error, :forbidden}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_portal_response}
    end
  end

  @doc """
  Syncs Stripe seat quantity for a billing account when membership changes.
  """
  def sync_subscription_quantity(billing_account_id) when is_binary(billing_account_id) do
    case Repo.get(BillingAccount, billing_account_id) do
      %BillingAccount{} = billing_account ->
        item_id = billing_account.stripe_subscription_item_id

        if effective_billing_mode(billing_account) == "standard" and is_binary(item_id) and
             item_id != "" do
          StripeClient.update_subscription_item(item_id, %{
            quantity: seat_count(billing_account_id)
          })
        end

        :ok

      nil ->
        :ok
    end
  end

  def sync_subscription_quantity(_), do: :ok

  @doc """
  Verifies and processes an incoming Stripe webhook.
  """
  def process_webhook(signature_header, raw_body)
      when is_binary(signature_header) and is_binary(raw_body) do
    with {:ok, secret} <- webhook_secret(),
         :ok <- verify_signature(signature_header, raw_body, secret),
         {:ok, event} <- Jason.decode(raw_body),
         :ok <- handle_event(event) do
      :ok
    end
  end

  def process_webhook(_, _), do: {:error, :invalid_request}

  defp ensure_checkout_ready(%BillingAccount{stripe_subscription_id: subscription_id})
       when is_binary(subscription_id) and subscription_id != "" do
    {:error, :subscription_exists}
  end

  defp ensure_checkout_ready(_billing_account), do: :ok

  defp ensure_stripe_customer(%BillingAccount{} = billing_account) do
    case billing_account.stripe_customer_id do
      customer_id when is_binary(customer_id) and customer_id != "" ->
        {:ok, billing_account}

      _ ->
        with {:ok, response} <-
               StripeClient.create_customer(%{
                 email: billing_account.billing_email,
                 name: billing_account.name,
                 metadata: %{
                   billing_account_id: billing_account.id
                 }
               }),
             customer_id when is_binary(customer_id) <- Map.get(response, "id"),
             {:ok, updated_account} <-
               billing_account
               |> BillingAccount.changeset(%{stripe_customer_id: customer_id})
               |> Repo.update() do
          {:ok, updated_account}
        else
          {:error, _reason} = error -> error
          _ -> {:error, :invalid_customer_response}
        end
    end
  end

  defp seat_count(billing_account_id), do: AccountFacts.seat_count(billing_account_id)

  defp upsert_usage_snapshot(attrs) do
    %BillingUsageSnapshot{}
    |> BillingUsageSnapshot.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :billing_account_id, :measured_at, :inserted_at]},
      conflict_target: [:billing_account_id, :measured_at],
      returning: true
    )
  end

  defp upsert_usage_report(billing_account, projection, identifier, reported_at) do
    attrs = %{
      billing_account_id: billing_account.id,
      period_start: projection.period_start,
      period_end: projection.period_end,
      sample_count:
        snapshot_count(billing_account.id, projection.period_start, projection.period_end),
      average_total_bytes:
        projected_total_bytes(billing_account, projection.projected_overage_bytes),
      average_overage_bytes: projection.projected_overage_bytes,
      reported_overage_units: projection.projected_overage_units,
      stripe_meter_event_identifier: identifier,
      reported_at: reported_at
    }

    %BillingUsageReport{}
    |> BillingUsageReport.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :sample_count,
           :average_total_bytes,
           :average_overage_bytes,
           :reported_overage_units,
           :stripe_meter_event_identifier,
           :reported_at
         ]},
      conflict_target: [:billing_account_id, :period_start, :period_end],
      returning: true
    )
  end

  defp projected_total_bytes(%BillingAccount{} = billing_account, overage_bytes) do
    included_storage_bytes(billing_account) + overage_bytes
  end

  defp snapshot_count(billing_account_id, period_start, period_end) do
    Repo.aggregate(
      from(snapshot in BillingUsageSnapshot,
        where: snapshot.billing_account_id == ^billing_account_id,
        where: snapshot.measured_at >= ^period_start and snapshot.measured_at < ^period_end
      ),
      :count,
      :id
    )
  end

  defp reportable_billing_account(%BillingAccount{} = billing_account) do
    case {effective_billing_mode(billing_account), effective_plan(billing_account)} do
      {"standard", "pro"} ->
        case billing_account.stripe_customer_id do
          customer_id when is_binary(customer_id) and customer_id != "" -> :ok
          _ -> {:error, :missing_customer}
        end

      _ ->
        {:error, :skip}
    end
  end

  defp storage_meter_event_name do
    case Application.get_env(:assistant, :stripe_storage_meter_event_name) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_storage_meter_event_name}
    end
  end

  defp meter_event_identifier(billing_account_id, as_of) do
    "storage-overage:#{billing_account_id}:#{DateTime.to_unix(as_of)}"
  end

  defp current_billing_period(%DateTime{} = as_of) do
    period_start =
      DateTime.new!(Date.beginning_of_month(DateTime.to_date(as_of)), ~T[00:00:00], "Etc/UTC")

    period_end =
      DateTime.new!(
        Date.beginning_of_month(
          Date.add(
            DateTime.to_date(period_start),
            Date.days_in_month(DateTime.to_date(period_start))
          )
        ),
        ~T[00:00:00],
        "Etc/UTC"
      )

    {period_start, period_end}
  end

  defp handle_event(%{"type" => "checkout.session.completed", "data" => %{"object" => object}}) do
    billing_account_id =
      get_in(object, ["metadata", "billing_account_id"]) || object["client_reference_id"]

    attrs = %{
      stripe_customer_id: object["customer"],
      stripe_subscription_id: object["subscription"],
      stripe_subscription_status: "pending_activation",
      plan: "pro",
      billing_mode: "standard"
    }

    update_billing_account(billing_account_id, attrs)
  end

  defp handle_event(%{"type" => type, "data" => %{"object" => object}})
       when type in ["customer.subscription.created", "customer.subscription.updated"] do
    billing_account_id =
      get_in(object, ["metadata", "billing_account_id"]) ||
        billing_account_id_for_customer(object["customer"])

    update_billing_account_from_subscription(billing_account_id, object)
  end

  defp handle_event(%{"type" => "customer.subscription.deleted", "data" => %{"object" => object}}) do
    billing_account_id =
      get_in(object, ["metadata", "billing_account_id"]) ||
        billing_account_id_for_customer(object["customer"])

    update_billing_account_from_subscription_deleted(billing_account_id, object)
  end

  defp handle_event(_event), do: :ok

  defp subscription_attrs(object) do
    status = object["status"]
    first_item = get_in(object, ["items", "data", Access.at(0)]) || %{}
    price_id = get_in(first_item, ["price", "id"])

    %{
      stripe_customer_id: object["customer"],
      stripe_subscription_id: object["id"],
      stripe_subscription_item_id: first_item["id"],
      stripe_subscription_status: status,
      stripe_price_id: price_id,
      stripe_current_period_end: unix_to_datetime(object["current_period_end"]),
      plan: if(active_subscription_status?(status), do: "pro", else: "free")
    }
  end

  defp update_billing_account(nil, _attrs), do: :ok

  defp update_billing_account(billing_account_id, attrs) when is_binary(billing_account_id) do
    case Repo.get(BillingAccount, billing_account_id) do
      nil ->
        :ok

      %BillingAccount{} = billing_account ->
        update_billing_account(billing_account, attrs)
    end
  end

  defp update_billing_account(%BillingAccount{} = billing_account, attrs) do
    case billing_account
         |> BillingAccount.changeset(attrs)
         |> Repo.update() do
      {:ok, _updated_account} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_billing_account_from_subscription(nil, _object), do: :ok

  defp update_billing_account_from_subscription(billing_account_id, object)
       when is_binary(billing_account_id) do
    case Repo.get(BillingAccount, billing_account_id) do
      nil ->
        :ok

      %BillingAccount{} = billing_account ->
        object
        |> subscription_attrs()
        |> maybe_preserve_manual_plan(billing_account)
        |> then(&update_billing_account(billing_account, &1))
    end
  end

  defp update_billing_account_from_subscription_deleted(nil, _object), do: :ok

  defp update_billing_account_from_subscription_deleted(billing_account_id, object)
       when is_binary(billing_account_id) do
    case Repo.get(BillingAccount, billing_account_id) do
      nil ->
        :ok

      %BillingAccount{} = billing_account ->
        attrs =
          %{
            stripe_subscription_id: nil,
            stripe_subscription_item_id: nil,
            stripe_subscription_status: object["status"],
            stripe_price_id: nil,
            stripe_current_period_end: nil,
            plan: "free"
          }
          |> maybe_preserve_manual_plan(billing_account)

        update_billing_account(billing_account, attrs)
    end
  end

  defp maybe_preserve_manual_plan(attrs, %BillingAccount{} = billing_account) do
    if effective_billing_mode(billing_account) == "standard" do
      attrs
    else
      Map.delete(attrs, :plan)
    end
  end

  defp billing_account_id_for_customer(customer_id) when is_binary(customer_id) do
    Repo.one(
      from(ba in BillingAccount,
        where: ba.stripe_customer_id == ^customer_id,
        select: ba.id
      )
    )
  end

  defp billing_account_id_for_customer(_), do: nil

  defp active_subscription_status?(status), do: AccountFacts.active_subscription_status?(status)

  defp effective_billing_mode(%BillingAccount{} = billing_account, as_of \\ DateTime.utc_now()),
    do: AccountFacts.effective_billing_mode(billing_account, as_of)

  defp effective_plan(%BillingAccount{} = billing_account),
    do: AccountFacts.effective_plan(billing_account)

  defp load_settings_user_billing_account(%SettingsUser{} = settings_user, opts) do
    if Keyword.get(opts, :ensure?, false) do
      ensure_billing_account(settings_user)
    else
      resolved_settings_user =
        if Ecto.assoc_loaded?(settings_user.billing_account) do
          settings_user
        else
          Repo.preload(settings_user, :billing_account)
        end

      {:ok, {resolved_settings_user, resolved_settings_user.billing_account}}
    end
  end

  defp normalize_billing_override_attrs(%BillingAccount{} = billing_account, attrs) do
    changeset = Ecto.Changeset.change(billing_account)
    billing_mode = map_attr(attrs, "billing_mode") || "standard"

    {seat_bonus, changeset} =
      parse_non_neg_integer_field(changeset, :seat_bonus, map_attr(attrs, "seat_bonus"))

    {storage_bonus_gb, changeset} =
      parse_non_neg_integer_field(
        changeset,
        :storage_bonus_bytes,
        map_attr(attrs, "storage_bonus_gb"),
        message: "must be a whole number of GB"
      )

    {complimentary_until, changeset} =
      parse_optional_utc_datetime_field(
        changeset,
        :complimentary_until,
        map_attr(attrs, "complimentary_until")
      )

    normalized_attrs = %{
      plan: map_attr(attrs, "plan") || "free",
      billing_mode: billing_mode,
      complimentary_until:
        if(billing_mode == "complimentary", do: complimentary_until, else: nil),
      seat_bonus: seat_bonus,
      storage_bonus_bytes: storage_bonus_gb * storage_overage_unit_bytes(),
      internal_notes: blank_to_nil(map_attr(attrs, "internal_notes"))
    }

    if changeset.valid? do
      {:ok, normalized_attrs}
    else
      {:error, changeset}
    end
  end

  defp parse_non_neg_integer_field(changeset, field, value, opts \\ [])

  defp parse_non_neg_integer_field(changeset, _field, nil, _opts), do: {0, changeset}
  defp parse_non_neg_integer_field(changeset, _field, "", _opts), do: {0, changeset}

  defp parse_non_neg_integer_field(changeset, field, value, opts) when is_integer(value) do
    if value >= 0 do
      {value, changeset}
    else
      {0,
       Ecto.Changeset.add_error(
         changeset,
         field,
         Keyword.get(opts, :message, "must be 0 or greater")
       )}
    end
  end

  defp parse_non_neg_integer_field(changeset, field, value, opts) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed >= 0 ->
        {parsed, changeset}

      _ ->
        {0,
         Ecto.Changeset.add_error(
           changeset,
           field,
           Keyword.get(opts, :message, "must be a non-negative whole number")
         )}
    end
  end

  defp parse_non_neg_integer_field(changeset, field, _value, opts) do
    {0,
     Ecto.Changeset.add_error(
       changeset,
       field,
       Keyword.get(opts, :message, "must be a non-negative whole number")
     )}
  end

  defp parse_optional_utc_datetime_field(changeset, _field, nil), do: {nil, changeset}
  defp parse_optional_utc_datetime_field(changeset, _field, ""), do: {nil, changeset}

  defp parse_optional_utc_datetime_field(changeset, _field, %DateTime{} = value),
    do: {value, changeset}

  defp parse_optional_utc_datetime_field(changeset, field, value) when is_binary(value) do
    case DateTime.from_iso8601(String.trim(value)) do
      {:ok, datetime, _offset} ->
        {datetime, changeset}

      _ ->
        {nil,
         Ecto.Changeset.add_error(
           changeset,
           field,
           "must be an ISO8601 UTC timestamp like 2026-04-01T12:30:00Z"
         )}
    end
  end

  defp parse_optional_utc_datetime_field(changeset, field, _value) do
    {nil,
     Ecto.Changeset.add_error(
       changeset,
       field,
       "must be an ISO8601 UTC timestamp like 2026-04-01T12:30:00Z"
     )}
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp map_attr(attrs, "plan"), do: Map.get(attrs, "plan") || Map.get(attrs, :plan)

  defp map_attr(attrs, "billing_mode"),
    do: Map.get(attrs, "billing_mode") || Map.get(attrs, :billing_mode)

  defp map_attr(attrs, "complimentary_until"),
    do: Map.get(attrs, "complimentary_until") || Map.get(attrs, :complimentary_until)

  defp map_attr(attrs, "seat_bonus"),
    do: Map.get(attrs, "seat_bonus") || Map.get(attrs, :seat_bonus)

  defp map_attr(attrs, "storage_bonus_gb"),
    do: Map.get(attrs, "storage_bonus_gb") || Map.get(attrs, :storage_bonus_gb)

  defp map_attr(attrs, "internal_notes"),
    do: Map.get(attrs, "internal_notes") || Map.get(attrs, :internal_notes)

  defp verify_signature(signature_header, raw_body, secret) do
    with {:ok, timestamp, signatures} <- parse_signature_header(signature_header),
         :ok <- validate_timestamp(timestamp),
         computed <- compute_signature(timestamp, raw_body, secret),
         true <- Enum.any?(signatures, &Plug.Crypto.secure_compare(&1, computed)) do
      :ok
    else
      false -> {:error, :invalid_signature}
      {:error, _reason} = error -> error
    end
  end

  defp parse_signature_header(signature_header) do
    parsed =
      signature_header
      |> String.split(",", trim: true)
      |> Enum.reduce(%{timestamp: nil, signatures: []}, fn part, acc ->
        case String.split(part, "=", parts: 2) do
          ["t", value] -> %{acc | timestamp: value}
          ["v1", value] -> %{acc | signatures: [value | acc.signatures]}
          _ -> acc
        end
      end)

    if is_binary(parsed.timestamp) and parsed.signatures != [] do
      {:ok, parsed.timestamp, parsed.signatures}
    else
      {:error, :invalid_signature_header}
    end
  end

  defp validate_timestamp(timestamp) do
    with {timestamp_int, ""} <- Integer.parse(timestamp),
         delta when delta <= 300 <- abs(System.system_time(:second) - timestamp_int) do
      :ok
    else
      _ -> {:error, :stale_signature}
    end
  end

  defp compute_signature(timestamp, raw_body, secret) do
    :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{raw_body}")
    |> Base.encode16(case: :lower)
  end

  defp unix_to_datetime(value) when is_integer(value), do: DateTime.from_unix!(value)
  defp unix_to_datetime(_), do: nil

  defp default_account_name(%SettingsUser{} = settings_user) do
    cond do
      is_binary(settings_user.full_name) and String.trim(settings_user.full_name) != "" ->
        String.trim(settings_user.full_name) <> "'s Workspace"

      is_binary(settings_user.display_name) and String.trim(settings_user.display_name) != "" ->
        String.trim(settings_user.display_name) <> "'s Workspace"

      is_binary(settings_user.email) ->
        settings_user.email
        |> String.split("@")
        |> List.first()
        |> Kernel.<>("'s Workspace")

      true ->
        "Workspace"
    end
  end

  defp success_url, do: AssistantWeb.Endpoint.url() <> "/settings?checkout=success"
  defp cancel_url, do: AssistantWeb.Endpoint.url() <> "/settings?checkout=canceled"
  defp return_url, do: AssistantWeb.Endpoint.url() <> "/settings"

  defp pro_price_id do
    case Application.get_env(:assistant, :stripe_pro_price_id) do
      price_id when is_binary(price_id) and price_id != "" -> {:ok, price_id}
      _ -> {:error, :missing_price_id}
    end
  end

  defp webhook_secret do
    case Application.get_env(:assistant, :stripe_webhook_secret) do
      secret when is_binary(secret) and secret != "" -> {:ok, secret}
      _ -> {:error, :missing_webhook_secret}
    end
  end
end
