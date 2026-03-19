defmodule Assistant.Encryption do
  @moduledoc """
  Runtime-selected facade for hosted content encryption.

  This facade is intentionally separate from `Assistant.Vault`, which continues
  to back existing Cloak-encrypted secret fields. Content encryption backends
  are selected via `:content_crypto` runtime config.
  """

  alias Assistant.Encryption.{LocalProvider, VaultTransitProvider}

  @type mode :: :local_cloak | :vault_transit

  @type field_ref :: %{
          required(:billing_account_id) => binary(),
          required(:table) => atom() | String.t(),
          required(:field) => atom() | String.t(),
          optional(:row_id) => binary() | nil,
          optional(:version) => pos_integer()
        }

  @type encrypted_payload :: %{
          required(:ciphertext) => String.t(),
          required(:nonce) => String.t(),
          required(:tag) => String.t(),
          optional(:wrapped_dek) => String.t() | nil,
          required(:key_version) => non_neg_integer(),
          required(:algorithm) => String.t(),
          required(:aad_version) => pos_integer()
        }

  @spec mode() :: mode()
  def mode do
    Application.get_env(:assistant, :content_crypto, [])
    |> Keyword.get(:mode, :local_cloak)
  end

  @spec hosted_mode?() :: boolean()
  def hosted_mode?, do: mode() == :vault_transit

  @spec provider_module() :: module()
  def provider_module do
    case mode() do
      :local_cloak -> LocalProvider
      :vault_transit -> VaultTransitProvider
    end
  end

  @spec configured?() :: boolean()
  def configured?, do: provider_module().configured?()

  @spec encrypt(field_ref(), binary(), keyword()) ::
          {:ok, encrypted_payload()} | {:error, term()}
  def encrypt(field_ref, plaintext, opts \\ []) when is_map(field_ref) and is_binary(plaintext) do
    provider_module().encrypt(field_ref, plaintext, opts)
  end

  @spec decrypt(field_ref(), encrypted_payload(), keyword()) :: {:ok, binary()} | {:error, term()}
  def decrypt(field_ref, encrypted_payload, opts \\ [])
      when is_map(field_ref) and is_map(encrypted_payload) do
    provider_module().decrypt(field_ref, encrypted_payload, opts)
  end
end
