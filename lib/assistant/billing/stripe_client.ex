defmodule Assistant.Billing.StripeClient do
  @moduledoc false

  require Logger

  @default_base_url "https://api.stripe.com"

  def create_customer(attrs), do: post_form("/v1/customers", attrs)
  def create_checkout_session(attrs), do: post_form("/v1/checkout/sessions", attrs)
  def create_portal_session(attrs), do: post_form("/v1/billing_portal/sessions", attrs)
  def create_meter_event(attrs), do: post_form("/v1/billing/meter_events", attrs)

  def update_subscription_item(item_id, attrs),
    do: post_form("/v1/subscription_items/#{item_id}", attrs)

  defp post_form(path, attrs) when is_map(attrs) do
    with {:ok, secret_key} <- secret_key() do
      url = api_base_url() <> path

      case Req.post(url,
             form: flatten_form(attrs),
             headers: [
               {"authorization", "Bearer #{secret_key}"},
               {"content-type", "application/x-www-form-urlencoded"}
             ],
             receive_timeout: 10_000,
             retry: false
           ) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          {:ok, body}

        {:ok, %Req.Response{status: status, body: body}} ->
          Logger.warning("Stripe API error", status: status, body: inspect(body))
          {:error, {:api_error, status, extract_error(body)}}

        {:error, reason} ->
          {:error, {:request_failed, reason}}
      end
    end
  end

  defp flatten_form(attrs) do
    attrs
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.flat_map(fn {key, value} -> flatten_pair([to_string(key)], value) end)
  end

  defp flatten_pair(_path, nil), do: []

  defp flatten_pair(path, value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.flat_map(fn {key, nested_value} ->
      flatten_pair(path ++ [to_string(key)], nested_value)
    end)
  end

  defp flatten_pair(path, value) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} ->
      flatten_pair(path ++ [Integer.to_string(index)], item)
    end)
  end

  defp flatten_pair(path, value) when is_boolean(value),
    do: [{encode_path(path), to_string(value)}]

  defp flatten_pair(path, value) when is_integer(value),
    do: [{encode_path(path), Integer.to_string(value)}]

  defp flatten_pair(path, value) when is_float(value),
    do: [{encode_path(path), :erlang.float_to_binary(value)}]

  defp flatten_pair(path, value), do: [{encode_path(path), to_string(value)}]

  defp encode_path([head | tail]) do
    Enum.reduce(tail, head, fn segment, acc -> acc <> "[#{segment}]" end)
  end

  defp extract_error(%{"error" => %{"message" => message}}) when is_binary(message), do: message
  defp extract_error(%{"error" => message}) when is_binary(message), do: message
  defp extract_error(body) when is_binary(body), do: body
  defp extract_error(_body), do: "Stripe request failed"

  defp secret_key do
    case Application.get_env(:assistant, :stripe_secret_key) do
      secret_key when is_binary(secret_key) and secret_key != "" -> {:ok, secret_key}
      _ -> {:error, :missing_secret_key}
    end
  end

  defp api_base_url do
    Application.get_env(:assistant, :stripe_api_base_url, @default_base_url)
  end
end
