# lib/assistant/accounts/cross_channel_bridge.ex
#
# Single-admin fallback logic for cross-channel API key resolution.
# Called by Assistant.Accounts when a direct user_id → settings_user
# lookup returns no key/credentials.
#
# See also: lib/assistant_web/live/settings_live/context.ex (ensure_linked_user)
# and priv/repo/migrations/*_repair_settings_user_pseudo_links.exs.

defmodule Assistant.Accounts.CrossChannelBridge do
  @moduledoc """
  Cross-channel API key resolution for single-admin deployments.

  ## Problem

  The `settings_users` table bridges web dashboard users to chat users via
  a `user_id` FK. When a chat message arrives (e.g. Telegram), the system
  looks up `settings_users.user_id = chat_user.id` to find the API key.

  In single-admin setups, the `settings_user` may have been linked to a
  "settings" pseudo-user (created by `ensure_linked_user`) instead of the
  actual chat user. This causes `openrouter_key_for_user(chat_user_id)` to
  return `nil` even though a key is stored.

  ## Fallback Strategy

  When the direct lookup fails, these functions check whether **exactly one**
  settings_user in the system has the requested key/credentials. If so, it is
  safe to return that value — the deployment has a single admin and the
  mismatch is a linking artifact, not an ambiguity.

  If multiple settings_users have keys, the fallback returns `nil` to avoid
  guessing (security assumption: ambiguity ≠ authorization).
  """

  import Ecto.Query, warn: false

  require Logger

  alias Assistant.Accounts.SettingsUser
  alias Assistant.Repo

  @doc """
  Returns the sole settings_user's value for `key_field` if exactly one
  settings_user has a non-null value, otherwise nil.

  This is the single-admin fallback for API key fields like
  `:openrouter_api_key` and `:openai_api_key`.
  """
  @spec sole_key(atom()) :: String.t() | nil
  def sole_key(key_field) when key_field in [:openrouter_api_key, :openai_api_key] do
    query =
      from(su in SettingsUser,
        where: not is_nil(field(su, ^key_field)),
        select: field(su, ^key_field)
      )

    case Repo.all(query) do
      [key] when is_binary(key) and key != "" -> key
      _ -> nil
    end
  end

  @doc """
  Returns the sole settings_user's full OpenAI credentials if exactly one
  settings_user has a non-null OpenAI key, otherwise nil.
  """
  @spec sole_credentials(:openai) :: map() | nil
  def sole_credentials(:openai) do
    query =
      from(su in SettingsUser,
        where: not is_nil(su.openai_api_key),
        select: %{
          auth_type: su.openai_auth_type,
          access_token: su.openai_api_key,
          refresh_token: su.openai_refresh_token,
          account_id: su.openai_account_id,
          expires_at: su.openai_expires_at
        }
      )

    case Repo.all(query) do
      [%{access_token: token} = row] when is_binary(token) and token != "" -> row
      _ -> nil
    end
  end

  @doc """
  Logs when a cross-channel fallback is used to resolve an API key.

  Call this from the public `*_for_user` functions in `Accounts` when the
  direct lookup returned nil but the fallback produced a result.
  """
  @spec log_fallback(String.t(), atom()) :: :ok
  def log_fallback(user_id, key_type) do
    Logger.info(
      "Cross-channel fallback: resolved #{key_type} for user #{user_id} via sole settings_user"
    )
  end
end
