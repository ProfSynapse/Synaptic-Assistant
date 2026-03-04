defmodule Assistant.Integrations.Web.UrlPolicy do
  @moduledoc """
  URL validation and SSRF protection for web fetches.
  """

  @type validation_error ::
          :invalid_url
          | :unsupported_scheme
          | :missing_host
          | :disallowed_host
          | :unresolved_host

  @spec validate(String.t()) :: {:ok, URI.t()} | {:error, validation_error()}
  def validate(url) when is_binary(url) do
    with %URI{} = uri <- URI.parse(String.trim(url)),
         :ok <- validate_scheme(uri.scheme),
         :ok <- validate_host(uri.host),
         :ok <- validate_resolved_host(uri.host) do
      {:ok, uri}
    else
      :error -> {:error, :invalid_url}
      {:error, _} = error -> error
    end
  end

  def validate(_), do: {:error, :invalid_url}

  defp validate_scheme(scheme) when scheme in ["http", "https"], do: :ok
  defp validate_scheme(_), do: {:error, :unsupported_scheme}

  defp validate_host(host) when is_binary(host) do
    downcased = String.downcase(host)

    cond do
      downcased == "" ->
        {:error, :missing_host}

      downcased in ["localhost", "localhost.localdomain"] ->
        {:error, :disallowed_host}

      true ->
        :ok
    end
  end

  defp validate_host(_), do: {:error, :missing_host}

  defp validate_resolved_host(host) do
    case :inet.getaddrs(String.to_charlist(host), :inet) do
      {:ok, addresses} ->
        if Enum.any?(addresses, &disallowed_ipv4?/1) do
          {:error, :disallowed_host}
        else
          validate_ipv6(host)
        end

      {:error, _} ->
        validate_ipv6(host)
    end
  end

  defp validate_ipv6(host) do
    case :inet.getaddrs(String.to_charlist(host), :inet6) do
      {:ok, addresses} ->
        if Enum.any?(addresses, &disallowed_ipv6?/1) do
          {:error, :disallowed_host}
        else
          :ok
        end

      {:error, _} ->
        case :inet.parse_ipv4_address(String.to_charlist(host)) do
          {:ok, tuple} ->
            if disallowed_ipv4?(tuple), do: {:error, :disallowed_host}, else: :ok

          {:error, _} ->
            case :inet.parse_ipv6_address(String.to_charlist(host)) do
              {:ok, tuple} ->
                if disallowed_ipv6?(tuple), do: {:error, :disallowed_host}, else: :ok

              {:error, _} ->
                {:error, :unresolved_host}
            end
        end
    end
  end

  defp disallowed_ipv4?({127, _, _, _}), do: true
  defp disallowed_ipv4?({10, _, _, _}), do: true
  defp disallowed_ipv4?({0, _, _, _}), do: true
  defp disallowed_ipv4?({169, 254, _, _}), do: true
  defp disallowed_ipv4?({172, second, _, _}) when second in 16..31, do: true
  defp disallowed_ipv4?({192, 168, _, _}), do: true
  defp disallowed_ipv4?({100, second, _, _}) when second in 64..127, do: true
  defp disallowed_ipv4?(_), do: false

  defp disallowed_ipv6?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp disallowed_ipv6?({64512, _, _, _, _, _, _, _}), do: true
  defp disallowed_ipv6?({64768, _, _, _, _, _, _, _}), do: true
  defp disallowed_ipv6?({65152, _, _, _, _, _, _, _}), do: true
  defp disallowed_ipv6?({0, 0, 0, 0, 0, 65535, 32512, _}), do: true
  defp disallowed_ipv6?(_), do: false
end
