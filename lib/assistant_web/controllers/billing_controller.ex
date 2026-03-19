defmodule AssistantWeb.BillingController do
  use AssistantWeb, :controller

  alias Assistant.Accounts.SettingsUser
  alias Assistant.Billing

  def create_checkout_session(conn, _params) do
    with {:ok, settings_user} <- current_settings_user(conn),
         {:ok, url} <- Billing.create_checkout_session(settings_user) do
      redirect(conn, external: url)
    else
      {:error, :forbidden} ->
        conn
        |> put_flash(:error, "Only a workspace billing admin can manage the plan.")
        |> redirect(to: ~p"/settings")

      {:error, :subscription_exists} ->
        conn
        |> put_flash(:info, "This workspace already has an active Stripe subscription.")
        |> redirect(to: ~p"/settings")

      {:error, :missing_price_id} ->
        conn
        |> put_flash(:error, "Stripe Pro pricing is not configured yet.")
        |> redirect(to: ~p"/settings")

      _ ->
        conn
        |> put_flash(:error, "Unable to start Stripe checkout.")
        |> redirect(to: ~p"/settings")
    end
  end

  def create_portal_session(conn, _params) do
    with {:ok, settings_user} <- current_settings_user(conn),
         {:ok, url} <- Billing.create_portal_session(settings_user) do
      redirect(conn, external: url)
    else
      {:error, :forbidden} ->
        conn
        |> put_flash(:error, "Only a workspace billing admin can manage the plan.")
        |> redirect(to: ~p"/settings")

      _ ->
        conn
        |> put_flash(:error, "Unable to open the Stripe billing portal.")
        |> redirect(to: ~p"/settings")
    end
  end

  defp current_settings_user(conn) do
    case conn.assigns[:current_scope] do
      %{settings_user: %SettingsUser{} = settings_user} -> {:ok, settings_user}
      _ -> {:error, :not_authenticated}
    end
  end
end
