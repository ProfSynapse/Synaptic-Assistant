# lib/assistant/integrations/google/auth.ex — Google OAuth2 token wrapper.
#
# Wraps Goth to provide a clean interface for fetching Google OAuth2 access
# tokens. Used by all Google API clients (Drive, Chat, Gmail, Calendar) to
# authenticate requests.
#
# Related files:
#   - lib/assistant/application.ex (starts Goth in the supervision tree)
#   - config/runtime.exs (Google credentials configuration)
#   - lib/assistant/integrations/google/drive.ex (consumer — Drive API)
#   - lib/assistant/integrations/google/chat.ex (consumer — Chat API)
#   - lib/assistant/integrations/google/gmail.ex (consumer — Gmail API)
#   - lib/assistant/integrations/google/calendar.ex (consumer — Calendar API)

defmodule Assistant.Integrations.Google.Auth do
  @moduledoc """
  Google OAuth2 token management via Goth.

  Provides a simple interface for fetching access tokens from the Goth
  process (`Assistant.Goth`). Tokens are automatically refreshed by Goth
  before expiry.

  ## Usage

      case Assistant.Integrations.Google.Auth.token() do
        {:ok, access_token} -> # use the token string
        {:error, reason} -> # handle missing credentials or refresh failure
      end
  """

  require Logger

  @goth_name Assistant.Goth

  @doc """
  Fetch a current access token from the Goth instance.

  Returns `{:ok, token_string}` on success or `{:error, reason}` on failure.
  The token is valid for at least a few minutes (Goth refreshes proactively).
  """
  @spec token() :: {:ok, String.t()} | {:error, term()}
  def token do
    case Goth.fetch(@goth_name) do
      {:ok, %{token: access_token}} ->
        {:ok, access_token}

      {:error, reason} = error ->
        Logger.warning("Failed to fetch Google access token: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Fetch a current access token, raising on failure.

  Useful in contexts where missing credentials indicate a configuration error
  that should not be silently handled.
  """
  @spec token!() :: String.t()
  def token! do
    case token() do
      {:ok, access_token} -> access_token
      {:error, reason} -> raise "Google Auth token fetch failed: #{inspect(reason)}"
    end
  end

  @doc """
  Check whether Google credentials are configured.

  Returns `true` if the `:google_credentials` application env is set.
  Useful for feature-gating code paths that depend on Google APIs.
  """
  @spec configured?() :: boolean()
  def configured? do
    Application.get_env(:assistant, :google_credentials) != nil
  end

  @doc """
  The required Google API scopes for this application.

  Centralized here so both `application.ex` (Goth startup) and any scope
  validation logic reference the same list.
  """
  @spec scopes() :: [String.t()]
  def scopes do
    [
      "https://www.googleapis.com/auth/chat.bot",
      "https://www.googleapis.com/auth/drive.readonly",
      "https://www.googleapis.com/auth/drive.file",
      "https://www.googleapis.com/auth/gmail.modify",
      "https://www.googleapis.com/auth/calendar"
    ]
  end
end
