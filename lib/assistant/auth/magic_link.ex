# lib/assistant/auth/magic_link.ex — Magic link lifecycle for OAuth authorization.
#
# Generates, validates, and consumes single-use magic link tokens backed by
# the auth_tokens table. Each token is a 32-byte cryptographically random
# value; only its SHA-256 hash is stored in the database. Tokens are single-use
# (consumed atomically via UPDATE WHERE used_at IS NULL) and expire after 10
# minutes.
#
# The generate flow also stores the PKCE code_verifier and pending_intent
# (encrypted) so the OAuth callback can complete the code exchange and replay
# the user's original command.
#
# Related files:
#   - lib/assistant/schemas/auth_token.ex (Ecto schema)
#   - lib/assistant/auth/oauth.ex (builds the authorization URL with PKCE)
#   - lib/assistant/auth/token_store.ex (stores the resulting OAuth tokens)
#   - lib/assistant_web/controllers/oauth_controller.ex (consumes the magic link)
#   - priv/repo/migrations/20260220130001_create_auth_tokens.exs

defmodule Assistant.Auth.MagicLink do
  @moduledoc """
  Single-use, time-limited magic link tokens for OAuth authorization flows.

  ## Lifecycle

  1. `generate/3` — creates a magic link token, stores its SHA-256 hash in
     `auth_tokens`, and returns the raw token (for URL construction) plus
     the authorization URL.

  2. `validate/1` — looks up the token hash, checks expiry and single-use,
     returns the auth_token record without consuming it (for pre-checks).

  3. `consume/1` — atomically marks the token as used (`UPDATE WHERE used_at
     IS NULL RETURNING *`), returns the record with code_verifier and
     pending_intent for the OAuth callback to use.

  ## Security Properties

  - 32-byte cryptographically random tokens (`:crypto.strong_rand_bytes/1`)
  - Only SHA-256 hash stored in DB (raw token never persisted)
  - Single-use: atomic consumption prevents replay attacks
  - 10-minute TTL
  - Rate limited: max 3 active (unused, unexpired) magic links per user
  """

  import Ecto.Query

  alias Assistant.Repo
  alias Assistant.Schemas.AuthToken
  alias Assistant.Auth.OAuth

  require Logger

  @token_bytes 32
  @ttl_minutes 10
  @max_active_per_user 3
  @purpose "oauth_google"

  # --- Public API ---

  @doc """
  Generate a magic link for OAuth authorization.

  Creates a cryptographically random token, stores its hash in auth_tokens
  with the PKCE code_verifier and pending_intent, and returns the raw token
  and the full Google authorization URL.

  ## Parameters

    - `user_id` — the user requesting authorization
    - `channel` — the channel through which the user is interacting
    - `pending_intent` — map with the original command to replay after OAuth:
      `%{message: str, conversation_id: uuid, channel: str, reply_context: map}`

  ## Returns

    `{:ok, %{token: raw_token, url: authorize_url, auth_token_id: uuid}}`
    `{:error, :rate_limited}` if the user has too many active magic links
    `{:error, reason}` for other failures
  """
  @spec generate(String.t(), String.t(), map()) ::
          {:ok, %{token: String.t(), url: String.t(), auth_token_id: String.t()}}
          | {:error, term()}
  def generate(user_id, channel, pending_intent) do
    with raw_token <- generate_raw_token(),
         token_hash <- hash_token(raw_token),
         {:ok, url, pkce} <- OAuth.authorize_url(user_id, channel, token_hash) do
      expires_at = DateTime.add(DateTime.utc_now(), @ttl_minutes * 60, :second)

      attrs = %{
        user_id: user_id,
        token_hash: token_hash,
        purpose: @purpose,
        code_verifier: pkce.code_verifier,
        pending_intent: pending_intent,
        expires_at: expires_at
      }

      # Rate check + invalidation + insert in a single transaction to prevent
      # concurrent requests bypassing the rate limit between the check and insert.
      Repo.transaction(fn ->
        case check_rate_limit(user_id) do
          :ok ->
            invalidate_existing(user_id)

            case %AuthToken{}
                 |> AuthToken.changeset(attrs)
                 |> Repo.insert() do
              {:ok, auth_token} ->
                Logger.info("Magic link generated",
                  user_id: user_id,
                  auth_token_id: auth_token.id,
                  expires_at: DateTime.to_iso8601(expires_at)
                )

                %{token: raw_token, url: url, auth_token_id: auth_token.id}

              {:error, changeset} ->
                Logger.error("Magic link insert failed",
                  user_id: user_id,
                  errors: inspect(changeset.errors)
                )

                Repo.rollback({:insert_failed, changeset})
            end

          {:error, :rate_limited} ->
            Repo.rollback(:rate_limited)
        end
      end)
    end
  end

  @doc """
  Validate a magic link token without consuming it.

  Checks that the token exists, has not been used, and has not expired.

  ## Returns

    `{:ok, %AuthToken{}}` if valid.
    `{:error, :not_found}` if no matching token hash exists.
    `{:error, :already_used}` if the token was already consumed.
    `{:error, :expired}` if the token's TTL has passed.
  """
  @spec validate(String.t()) ::
          {:ok, AuthToken.t()}
          | {:error, :not_found | :already_used | :expired}
  def validate(raw_token) do
    token_hash = hash_token(raw_token)

    case Repo.one(from(t in AuthToken, where: t.token_hash == ^token_hash)) do
      nil ->
        {:error, :not_found}

      %AuthToken{used_at: used_at} when not is_nil(used_at) ->
        {:error, :already_used}

      %AuthToken{expires_at: expires_at} = auth_token ->
        if DateTime.compare(DateTime.utc_now(), expires_at) == :lt do
          {:ok, auth_token}
        else
          {:error, :expired}
        end
    end
  end

  @doc """
  Atomically consume a magic link token.

  Sets `used_at` to now via `UPDATE ... WHERE used_at IS NULL RETURNING *`.
  This ensures single-use semantics even under concurrent requests.

  ## Returns

    `{:ok, %AuthToken{}}` with `code_verifier` and `pending_intent` populated.
    `{:error, :not_found}` if no matching unused token exists.
    `{:error, :expired}` if the token's TTL has passed.
    `{:error, :already_used}` if another request consumed it first (race).
  """
  @spec consume(String.t()) ::
          {:ok, AuthToken.t()}
          | {:error, :not_found | :already_used | :expired}
  def consume(raw_token) do
    token_hash = hash_token(raw_token)
    now = DateTime.utc_now()

    # First check existence and expiry for specific error messages
    case Repo.one(from(t in AuthToken, where: t.token_hash == ^token_hash)) do
      nil ->
        {:error, :not_found}

      %AuthToken{used_at: used_at} when not is_nil(used_at) ->
        {:error, :already_used}

      %AuthToken{expires_at: expires_at} ->
        if DateTime.compare(now, expires_at) != :lt do
          {:error, :expired}
        else
          atomic_consume(token_hash, now)
        end
    end
  end

  @doc """
  Clean up expired auth_tokens older than 24 hours.

  Intended to be called by a recurring Oban job.
  Returns the number of deleted rows.
  """
  @spec cleanup_expired() :: non_neg_integer()
  def cleanup_expired do
    cutoff = DateTime.add(DateTime.utc_now(), -24 * 60 * 60, :second)

    {count, _} =
      from(t in AuthToken,
        where: t.expires_at < ^cutoff
      )
      |> Repo.delete_all()

    if count > 0 do
      Logger.info("Cleaned up expired auth tokens", count: count)
    end

    count
  end

  # --- Private Helpers ---

  defp generate_raw_token do
    :crypto.strong_rand_bytes(@token_bytes)
    |> Base.url_encode64(padding: false)
  end

  @doc false
  def hash_token(raw_token) do
    :crypto.hash(:sha256, raw_token)
    |> Base.url_encode64(padding: false)
  end

  defp atomic_consume(token_hash, now) do
    query =
      from(t in AuthToken,
        where: t.token_hash == ^token_hash and is_nil(t.used_at),
        select: t
      )

    case Repo.update_all(query, set: [used_at: now]) do
      {1, [auth_token]} ->
        Logger.info("Magic link consumed",
          auth_token_id: auth_token.id,
          user_id: auth_token.user_id
        )

        {:ok, auth_token}

      {0, _} ->
        # Another request consumed it between our check and update
        {:error, :already_used}
    end
  end

  defp check_rate_limit(user_id) do
    now = DateTime.utc_now()

    count =
      from(t in AuthToken,
        where:
          t.user_id == ^user_id and
            t.purpose == ^@purpose and
            is_nil(t.used_at) and
            t.expires_at > ^now
      )
      |> Repo.aggregate(:count)

    if count >= @max_active_per_user do
      Logger.warning("Magic link rate limit hit", user_id: user_id, active_count: count)
      {:error, :rate_limited}
    else
      :ok
    end
  end

  defp invalidate_existing(user_id) do
    now = DateTime.utc_now()

    {count, _} =
      from(t in AuthToken,
        where:
          t.user_id == ^user_id and
            t.purpose == ^@purpose and
            is_nil(t.used_at)
      )
      |> Repo.update_all(set: [used_at: now])

    if count > 0 do
      Logger.info("Invalidated existing magic links",
        user_id: user_id,
        invalidated_count: count
      )
    end
  end
end
