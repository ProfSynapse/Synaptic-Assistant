defmodule Assistant.Encryption.VaultTransitProvider do
  @moduledoc """
  Vault Transit-backed envelope encryption provider for hosted deployments.
  """

  @behaviour Assistant.Encryption.Provider

  alias Assistant.Encryption.{Cache, Context}

  @algorithm "aes_256_gcm"
  @tag_length 16

  @impl true
  def configured? do
    vault_config()
    |> Keyword.get(:addr)
    |> is_binary()
  end

  @impl true
  def encrypt(field_ref, plaintext, _opts) when is_binary(plaintext) do
    with {:ok, data_key} <- generate_data_key(field_ref) do
      nonce = :crypto.strong_rand_bytes(12)
      aad = Context.aad(field_ref)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(
          :aes_256_gcm,
          data_key.plaintext,
          nonce,
          plaintext,
          aad,
          @tag_length,
          true
        )

      {:ok,
       %{
         ciphertext: Base.encode64(ciphertext),
         nonce: Base.encode64(nonce),
         tag: Base.encode64(tag),
         wrapped_dek: data_key.wrapped_dek,
         key_version: data_key.key_version,
         algorithm: @algorithm,
         aad_version: Context.aad_version()
       }}
    end
  end

  @impl true
  def decrypt(field_ref, encrypted_payload, _opts) when is_map(encrypted_payload) do
    with {:ok, wrapped_dek} <- fetch_string_field(encrypted_payload, :wrapped_dek),
         {:ok, dek} <- unwrap_data_key(field_ref, wrapped_dek),
         {:ok, ciphertext} <- decode_field(encrypted_payload, :ciphertext),
         {:ok, nonce} <- decode_field(encrypted_payload, :nonce),
         {:ok, tag} <- decode_field(encrypted_payload, :tag) do
      aad = Context.aad(field_ref)

      case :crypto.crypto_one_time_aead(:aes_256_gcm, dek, nonce, ciphertext, aad, tag, false) do
        plaintext when is_binary(plaintext) -> {:ok, plaintext}
        :error -> {:error, :decrypt_failed}
      end
    end
  end

  defp generate_data_key(field_ref) do
    path = "/v1/#{transit_mount()}/datakey/plaintext/#{transit_key()}"

    body = %{
      bits: 256,
      context: Context.derivation_context(field_ref)
    }

    with {:ok, %{"data" => %{"plaintext" => plaintext_b64, "ciphertext" => wrapped_dek}}} <-
           request(:post, path, body),
         {:ok, plaintext} <- Base.decode64(plaintext_b64) do
      {:ok,
       %{
         plaintext: plaintext,
         wrapped_dek: wrapped_dek,
         key_version: key_version_from_ciphertext(wrapped_dek)
       }}
    end
  end

  defp unwrap_data_key(field_ref, wrapped_dek) do
    cache_key = :crypto.hash(:sha256, wrapped_dek)

    case Cache.get(cache_key) do
      {:ok, dek} ->
        {:ok, dek}

      :miss ->
        path = "/v1/#{transit_mount()}/decrypt/#{transit_key()}"

        body = %{
          ciphertext: wrapped_dek,
          context: Context.derivation_context(field_ref)
        }

        with {:ok, %{"data" => %{"plaintext" => plaintext_b64}}} <- request(:post, path, body),
             {:ok, dek} <- Base.decode64(plaintext_b64) do
          :ok = Cache.put(cache_key, dek)
          {:ok, dek}
        end
    end
  end

  defp request(method, path, body) do
    request =
      Req.new(
        base_url: Keyword.fetch!(vault_config(), :addr),
        headers: request_headers(),
        receive_timeout: Keyword.get(vault_config(), :timeout_ms, 5_000)
      )

    case Req.request(request, method: method, url: path, json: body) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:vault_error, status, body}}

      {:error, reason} ->
        {:error, {:vault_request_failed, reason}}
    end
  end

  defp request_headers do
    vault_config()
    |> Enum.reduce([], fn
      {:token, token}, headers when is_binary(token) ->
        [{"x-vault-token", token} | headers]

      {:namespace, namespace}, headers when is_binary(namespace) ->
        [{"x-vault-namespace", namespace} | headers]

      _entry, headers ->
        headers
    end)
  end

  defp vault_config do
    Application.get_env(:assistant, :content_crypto, [])
    |> Keyword.get(:vault, [])
  end

  defp transit_mount do
    Keyword.get(vault_config(), :transit_mount, "transit")
  end

  defp transit_key do
    Keyword.get(vault_config(), :transit_key, "assistant-content")
  end

  defp key_version_from_ciphertext("vault:v" <> rest) do
    case Integer.parse(rest) do
      {version, _} when version >= 0 -> version
      _ -> 0
    end
  end

  defp key_version_from_ciphertext(_), do: 0

  defp decode_field(payload, key) do
    with {:ok, value} <- fetch_string_field(payload, key) do
      Base.decode64(value)
    end
  end

  defp fetch_string_field(payload, key) do
    case payload do
      %{^key => value} when is_binary(value) -> {:ok, value}
      _ -> {:error, {:missing_field, key}}
    end
  end
end
