defmodule Assistant.Encryption.LocalProvider do
  @moduledoc """
  Local content encryption backend for self-hosted, dev, and test deployments.

  This is intentionally separate from the existing Cloak-backed secret-field
  path. It derives a per-context AES-256-GCM key from a local master key.
  """

  @behaviour Assistant.Encryption.Provider

  alias Assistant.Encryption.Context

  @algorithm "aes_256_gcm"
  @tag_length 16

  @impl true
  def configured? do
    local_config()
    |> Keyword.get(:key)
    |> is_binary()
  end

  @impl true
  def encrypt(field_ref, plaintext, _opts) when is_binary(plaintext) do
    with {:ok, key} <- content_key(),
         derived_key <- derive_key(key, field_ref) do
      nonce = :crypto.strong_rand_bytes(12)
      aad = Context.aad(field_ref)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(
          :aes_256_gcm,
          derived_key,
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
         wrapped_dek: nil,
         key_version: 1,
         algorithm: @algorithm,
         aad_version: Context.aad_version()
       }}
    end
  end

  @impl true
  def decrypt(field_ref, encrypted_payload, _opts) when is_map(encrypted_payload) do
    with {:ok, key} <- content_key(),
         derived_key <- derive_key(key, field_ref),
         {:ok, ciphertext} <- decode_field(encrypted_payload, :ciphertext),
         {:ok, nonce} <- decode_field(encrypted_payload, :nonce),
         {:ok, tag} <- decode_field(encrypted_payload, :tag) do
      aad = Context.aad(field_ref)

      case :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             derived_key,
             nonce,
             ciphertext,
             aad,
             tag,
             false
           ) do
        plaintext when is_binary(plaintext) -> {:ok, plaintext}
        :error -> {:error, :decrypt_failed}
      end
    end
  end

  defp local_config do
    Application.get_env(:assistant, :content_crypto, [])
    |> Keyword.get(:local, [])
  end

  defp content_key do
    case Keyword.get(local_config(), :key) do
      key when is_binary(key) and byte_size(key) == 32 -> {:ok, key}
      _ -> {:error, :not_configured}
    end
  end

  defp derive_key(master_key, field_ref) do
    :crypto.mac(:hmac, :sha256, master_key, Context.derivation_context(field_ref))
  end

  defp decode_field(payload, key) do
    string_key = to_string(key)
    atom_key = try do String.to_existing_atom(string_key) rescue _ -> key end
    
    case payload do
      %{^atom_key => value} when is_binary(value) ->
        case Base.decode64(value) do
          {:ok, decoded} -> {:ok, decoded}
          :error -> {:error, {:invalid_base64, key}}
        end

      %{^string_key => value} when is_binary(value) ->
        case Base.decode64(value) do
          {:ok, decoded} -> {:ok, decoded}
          :error -> {:error, {:invalid_base64, key}}
        end

      _ ->
        {:error, {:missing_field, key}}
    end
  end
end
