# lib/assistant/encryption/retry.ex — Retry helper for transient decrypt failures.
#
# Wraps a decrypt function with exponential backoff (100ms, 200ms) to handle
# transient Vault Transit errors (network blips, brief unavailability).
# Used by Content modules during hydration to avoid crashing on recoverable errors.
#
# Related files:
#   - lib/assistant/encryption.ex (facade that performs actual decrypt)
#   - lib/assistant/memory/content.ex, messages/content.ex, etc. (callers)

defmodule Assistant.Encryption.Retry do
  @moduledoc false

  @max_retries 2

  @doc """
  Calls `decrypt_fn` (a zero-arity function returning `{:ok, _}` or `{:error, _}`),
  retrying up to #{@max_retries} times with exponential backoff on failure.
  """
  @spec with_retry((-> {:ok, term()} | {:error, term()})) :: {:ok, term()} | {:error, term()}
  def with_retry(decrypt_fn), do: attempt(decrypt_fn, 0)

  defp attempt(decrypt_fn, retries) do
    case decrypt_fn.() do
      {:ok, _} = ok ->
        ok

      # Circuit open — Vault is known-down, retrying is pointless
      {:error, :vault_circuit_open} = error ->
        error

      {:error, _reason} = error when retries >= @max_retries ->
        error

      {:error, _reason} ->
        backoff_ms = trunc(:math.pow(2, retries) * 100)
        Process.sleep(backoff_ms)
        attempt(decrypt_fn, retries + 1)
    end
  end
end
