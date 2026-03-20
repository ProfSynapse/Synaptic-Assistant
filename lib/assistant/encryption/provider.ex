defmodule Assistant.Encryption.Provider do
  @moduledoc """
  Behaviour for runtime-selected content encryption providers.
  """

  @callback configured?() :: boolean()

  @callback encrypt(Assistant.Encryption.field_ref(), binary(), keyword()) ::
              {:ok, Assistant.Encryption.encrypted_payload()} | {:error, term()}

  @callback decrypt(
              Assistant.Encryption.field_ref(),
              Assistant.Encryption.encrypted_payload(),
              keyword()
            ) ::
              {:ok, binary()} | {:error, term()}
end
