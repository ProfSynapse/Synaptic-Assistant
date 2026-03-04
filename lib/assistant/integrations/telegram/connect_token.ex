defmodule Assistant.Integrations.Telegram.ConnectToken do
  @moduledoc """
  Single-use tokens for linking a Telegram account to an existing user.

  Tokens are delivered through Telegram deep links and stored in `auth_tokens`
  as SHA-256 hashes. Generating a new link invalidates prior unused link tokens
  for the same user to keep the flow single-use and short-lived.
  """

  import Ecto.Query

  alias Assistant.Repo
  alias Assistant.Schemas.AuthToken

  require Logger

  @token_bytes 32
  @ttl_minutes 10
  @purpose "telegram_connect"

  @spec generate(String.t()) ::
          {:ok, %{token: String.t(), auth_token_id: String.t(), expires_at: DateTime.t()}}
          | {:error, term()}
  def generate(user_id) when is_binary(user_id) do
    raw_token = generate_raw_token()
    token_hash = hash_token(raw_token)
    expires_at = DateTime.add(DateTime.utc_now(), @ttl_minutes * 60, :second)

    attrs = %{
      user_id: user_id,
      token_hash: token_hash,
      purpose: @purpose,
      expires_at: expires_at
    }

    Repo.transaction(fn ->
      invalidate_existing(user_id)

      case %AuthToken{} |> AuthToken.changeset(attrs) |> Repo.insert() do
        {:ok, auth_token} ->
          Logger.info("Telegram connect link generated",
            user_id: user_id,
            auth_token_id: auth_token.id,
            expires_at: DateTime.to_iso8601(expires_at)
          )

          %{token: raw_token, auth_token_id: auth_token.id, expires_at: expires_at}

        {:error, changeset} ->
          Repo.rollback({:insert_failed, changeset})
      end
    end)
  end

  @spec consume(String.t()) ::
          {:ok, AuthToken.t()} | {:error, :not_found | :already_used | :expired}
  def consume(raw_token) when is_binary(raw_token) do
    token_hash = hash_token(raw_token)
    now = DateTime.utc_now()

    case Repo.one(token_query(token_hash)) do
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

  @spec invalidate_user_tokens(String.t()) :: non_neg_integer()
  def invalidate_user_tokens(user_id) when is_binary(user_id) do
    now = DateTime.utc_now()
    invalidate_existing(user_id, now)
  end

  @doc false
  def hash_token(raw_token) do
    :crypto.hash(:sha256, raw_token)
    |> Base.url_encode64(padding: false)
  end

  defp generate_raw_token do
    :crypto.strong_rand_bytes(@token_bytes)
    |> Base.url_encode64(padding: false)
  end

  defp atomic_consume(token_hash, now) do
    query =
      from(t in AuthToken,
        where: t.token_hash == ^token_hash and t.purpose == ^@purpose and is_nil(t.used_at),
        select: t
      )

    case Repo.update_all(query, set: [used_at: now]) do
      {1, [auth_token]} ->
        {:ok, auth_token}

      {0, _} ->
        {:error, :already_used}
    end
  end

  defp invalidate_existing(user_id, used_at \\ DateTime.utc_now()) do
    {count, _} =
      from(t in AuthToken,
        where:
          t.user_id == ^user_id and t.purpose == ^@purpose and is_nil(t.used_at) and
            t.expires_at > ^used_at
      )
      |> Repo.update_all(set: [used_at: used_at])

    count
  end

  defp token_query(token_hash) do
    from(t in AuthToken,
      where: t.token_hash == ^token_hash and t.purpose == ^@purpose
    )
  end
end
