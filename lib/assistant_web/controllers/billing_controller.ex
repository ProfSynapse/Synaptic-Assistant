defmodule AssistantWeb.BillingController do
  use AssistantWeb, :controller

  alias Assistant.Accounts.SettingsUser
  alias Assistant.Billing
  alias Assistant.Deployment
  alias AssistantWeb.SettingsUserAuth

  def start_free(conn, _params) do
    if Deployment.self_hosted?() do
      redirect_self_hosted(conn)
    else
      case current_settings_user(conn) do
        {:ok, _settings_user} ->
          redirect(conn, to: SettingsUserAuth.signed_in_path(conn))

        {:error, :not_authenticated} ->
          conn
          |> put_session(:settings_user_return_to, ~p"/workspace")
          |> redirect(to: ~p"/settings_users/register")
      end
    end
  end

  def start_pro(conn, _params) do
    if Deployment.self_hosted?() do
      redirect_self_hosted(conn)
    else
      case current_settings_user(conn) do
        {:ok, settings_user} ->
          redirect_to_checkout(conn, settings_user)

        {:error, :not_authenticated} ->
          conn
          |> put_session(:settings_user_return_to, ~p"/pricing/pro")
          |> redirect(to: ~p"/settings_users/register")
      end
    end
  end

  def create_checkout_session(conn, _params) do
    if Deployment.self_hosted?() do
      redirect_self_hosted(conn)
    else
      with {:ok, settings_user} <- current_settings_user(conn) do
        redirect_to_checkout(conn, settings_user)
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
  end

  def create_portal_session(conn, _params) do
    if Deployment.self_hosted?() do
      redirect_self_hosted(conn)
    else
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
  end

  defp current_settings_user(conn) do
    case conn.assigns[:current_scope] do
      %{settings_user: %SettingsUser{} = settings_user} -> {:ok, settings_user}
      _ -> {:error, :not_authenticated}
    end
  end

  defp redirect_to_checkout(conn, %SettingsUser{} = settings_user) do
    case Billing.create_checkout_session(settings_user) do
      {:ok, url} ->
        redirect(conn, external: url)

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

  defp redirect_self_hosted(conn) do
    target =
      case current_settings_user(conn) do
        {:ok, _settings_user} -> ~p"/workspace"
        {:error, :not_authenticated} -> ~p"/settings_users/log-in"
      end

    conn
    |> put_flash(:info, "Stripe billing is disabled in self-hosted deployments.")
    |> redirect(to: target)
  end
end
