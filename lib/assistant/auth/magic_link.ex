# lib/assistant/auth/magic_link.ex — Generate, validate, and consume magic link tokens.
#
# Magic links are single-use, time-limited tokens delivered via the bot channel.
# They allow users to start the OAuth2 flow without needing a direct login page.
# Tokens are 32 bytes of cryptographic randomness; only the SHA-256 hash is stored
# in the database (auth_tokens table). TTL: 10 minutes. Single-use: atomic
# UPDATE WHERE used_at IS NULL RETURNING *.
#
# Related files:
#   - lib/assistant/auth/oauth.ex (builds the OAuth URL using magic link token hash)
#   - lib/assistant/schemas/auth_token.ex (Ecto schema for auth_tokens table)
#   - lib/assistant_web/controllers/oauth_controller.ex (validates magic link on /auth/google/start)

defmodule Assistant.Auth.MagicLink do
  @moduledoc """
  Generate, validate, and consume single-use magic link tokens.

  ## Security Properties

  - 32-byte cryptographically random token (`:crypto.strong_rand_bytes/1`)
  - Only SHA-256 hash stored in database (raw token never persisted)
  - 10-minute TTL
  - Single-use: atomic `UPDATE ... WHERE used_at IS NULL RETURNING *`
  - Latest-wins: generating a new magic link invalidates pending ones for same user
  - Rate limited: max 3 magic links per hour per user (enforced by caller)
  """

  require Logger

  import Ecto.Query

  alias Assistant.Repo
  alias Assistant.Schemas.AuthToken

  @token_bytes 32
  @ttl_minutes 10

  @doc """
  Generate a new magic link token for a user.

  Invalidates any existing pending magic link for the same user and purpose
  (latest-wins policy per plan decision). Stores the SHA-256 hash of the token
  in the `auth_tokens` table.

  If `:pending_intent` is provided, a PendingIntentWorker Oban job is inserted
  with `scheduled_at` 24 hours in the future (parked). The returned `oban_job_id`
  is stored in the auth_token row so the OAuthController can reschedule it after
  successful token exchange.

  ## Parameters

    * `user_id` - The user's UUID
    * `opts` - Keyword list:
      * `:purpose` - Token purpose (default: `"oauth_google"`)
      * `:pending_intent` - Map with keys: `:message`, `:conversation_id`,
        `:channel`, `:reply_context`. When provided, a parked Oban job is created.

  ## Returns

    `{:ok, %{token: raw_token, token_hash: hash, url: magic_link_url}}` on success.
    `{:error, changeset}` on failure.
  """
  @spec generate(binary(), keyword()) ::
          {:ok, %{token: String.t(), token_hash: String.t(), url: String.t()}}
          | {:error, term()}
  def generate(user_id, opts \\ []) do
    purpose = Keyword.get(opts, :purpose, "oauth_google")
    pending_intent = Keyword.get(opts, :pending_intent)

    raw_token = :crypto.strong_rand_bytes(@token_bytes) |> Base.url_encode64(padding: false)
    token_hash = hash_token(raw_token)
    expires_at = DateTime.add(DateTime.utc_now(), @ttl_minutes * 60, :second)

    Repo.transaction(fn ->
      # Invalidate existing pending magic links for this user+purpose (latest-wins)
      invalidate_pending(user_id, purpose)

      # Park a PendingIntentWorker Oban job if pending_intent is provided
      oban_job_id = maybe_insert_pending_intent_job(user_id, pending_intent)

      attrs = %{
        user_id: user_id,
        token_hash: token_hash,
        purpose: purpose,
        oban_job_id: oban_job_id,
        expires_at: expires_at
      }

      case Repo.insert(AuthToken.changeset(%AuthToken{}, attrs)) do
        {:ok, _auth_token} ->
          url = build_magic_link_url(raw_token)

          Logger.info("Magic link generated",
            user_id: user_id,
            purpose: purpose,
            oban_job_id: oban_job_id,
            expires_at: DateTime.to_iso8601(expires_at)
          )

          %{token: raw_token, token_hash: token_hash, url: url}

        {:error, changeset} ->
          Logger.error("Failed to generate magic link",
            user_id: user_id,
            errors: inspect(changeset.errors)
          )

          Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Validate a magic link token without consuming it.

  Checks that the token exists, has not been used, and has not expired.
  Used by the OAuth start endpoint to verify the magic link before redirecting
  to Google consent.

  ## Parameters

    * `raw_token` - The raw token string from the magic link URL

  ## Returns

    `{:ok, %{user_id: binary(), oban_job_id: integer() | nil}}` on success.
    `{:error, :not_found | :expired | :already_used}` on failure.
  """
  @spec validate(String.t()) ::
          {:ok, %{user_id: binary(), oban_job_id: integer() | nil}}
          | {:error, :not_found | :expired | :already_used}
  def validate(raw_token) do
    token_hash = hash_token(raw_token)

    case Repo.one(from(t in AuthToken, where: t.token_hash == ^token_hash)) do
      nil ->
        {:error, :not_found}

      %AuthToken{used_at: used_at} when not is_nil(used_at) ->
        {:error, :already_used}

      %AuthToken{expires_at: expires_at} = auth_token ->
        if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
          {:ok, %{user_id: auth_token.user_id, oban_job_id: auth_token.oban_job_id}}
        else
          {:error, :expired}
        end
    end
  end

  @doc """
  Consume a magic link token atomically (single-use).

  Uses `UPDATE ... WHERE used_at IS NULL RETURNING *` to ensure atomic
  single-use consumption. If two requests race, only one succeeds.

  ## Parameters

    * `raw_token` - The raw token string from the magic link URL

  ## Returns

    `{:ok, %AuthToken{}}` on success (token is now consumed).
    `{:error, :not_found | :expired | :already_used}` on failure.
  """
  @spec consume(String.t()) ::
          {:ok, AuthToken.t()} | {:error, :not_found | :expired | :already_used}
  def consume(raw_token) do
    token_hash = hash_token(raw_token)
    now = DateTime.utc_now()

    # Atomic single-use: UPDATE WHERE used_at IS NULL AND expires_at > now
    query =
      from(t in AuthToken,
        where: t.token_hash == ^token_hash and is_nil(t.used_at) and t.expires_at > ^now,
        select: t
      )

    case Repo.update_all(query, set: [used_at: now]) do
      {1, [auth_token]} ->
        Logger.info("Magic link consumed",
          user_id: auth_token.user_id,
          purpose: auth_token.purpose
        )

        {:ok, auth_token}

      {0, _} ->
        # Determine specific error reason
        determine_consume_error(token_hash)
    end
  end

  # --- Private Helpers ---

  # Insert a parked PendingIntentWorker Oban job scheduled 24h in the future.
  # Returns the oban_job_id on success, or nil if no pending_intent was provided.
  defp maybe_insert_pending_intent_job(_user_id, nil), do: nil

  defp maybe_insert_pending_intent_job(user_id, pending_intent) when is_map(pending_intent) do
    far_future = DateTime.add(DateTime.utc_now(), 24 * 60 * 60, :second)

    job_args = %{
      user_id: user_id,
      conversation_id: pending_intent[:conversation_id] || pending_intent["conversation_id"] || "",
      original_message: pending_intent[:message] || pending_intent["message"] || "",
      channel: pending_intent[:channel] || pending_intent["channel"] || "unknown",
      reply_context: pending_intent[:reply_context] || pending_intent["reply_context"] || %{}
    }

    case Assistant.Workers.PendingIntentWorker.new(job_args, scheduled_at: far_future)
         |> Oban.insert() do
      {:ok, %Oban.Job{id: job_id}} ->
        Logger.info("Parked PendingIntentWorker job",
          oban_job_id: job_id,
          user_id: user_id
        )

        job_id

      {:error, reason} ->
        Logger.error("Failed to insert PendingIntentWorker job",
          user_id: user_id,
          reason: inspect(reason)
        )

        nil
    end
  end

  defp hash_token(raw_token) do
    :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)
  end

  defp build_magic_link_url(raw_token) do
    host = Application.get_env(:assistant, AssistantWeb.Endpoint)[:url][:host] || "localhost"
    "https://#{host}/auth/google/start?token=#{raw_token}"
  end

  # Invalidate (mark as used) any pending magic links for this user+purpose.
  # This implements the "latest-wins" policy from the plan.
  defp invalidate_pending(user_id, purpose) do
    now = DateTime.utc_now()

    from(t in AuthToken,
      where:
        t.user_id == ^user_id and
          t.purpose == ^purpose and
          is_nil(t.used_at) and
          t.expires_at > ^now
    )
    |> Repo.update_all(set: [used_at: now])
  end

  defp determine_consume_error(token_hash) do
    case Repo.one(from(t in AuthToken, where: t.token_hash == ^token_hash)) do
      nil -> {:error, :not_found}
      %AuthToken{used_at: used_at} when not is_nil(used_at) -> {:error, :already_used}
      %AuthToken{} -> {:error, :expired}
    end
  end
end
