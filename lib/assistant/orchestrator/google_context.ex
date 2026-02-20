# lib/assistant/orchestrator/google_context.ex — Shared Google token and drive helpers.
#
# Extracted from loop_runner.ex and sub_agent.ex to eliminate duplication.
# Both modules call these helpers when building a Skills.Context for skill execution.
#
# Related files:
#   - lib/assistant/orchestrator/loop_runner.ex (uses in build_skill_context/1)
#   - lib/assistant/orchestrator/sub_agent.ex (uses in build_skill_context/2)
#   - lib/assistant/integrations/google/auth.ex (token refresh)
#   - lib/assistant/connected_drives.ex (drive scoping)

defmodule Assistant.Orchestrator.GoogleContext do
  @moduledoc false

  @doc """
  Resolve a per-user Google access token.

  Returns the token string on success, or nil if the user is unknown,
  not connected, or refresh fails. Skills handle nil tokens by returning
  auth error messages, and lazy auth handles the reconnect flow.
  """
  @spec resolve_google_token(String.t()) :: String.t() | nil
  def resolve_google_token("unknown"), do: nil

  def resolve_google_token(user_id) do
    case Assistant.Integrations.Google.Auth.user_token(user_id) do
      {:ok, token} -> token
      {:error, _} -> nil
    end
  end

  @doc """
  Load the list of enabled connected drives for a user.

  Returns a list of maps with `:drive_id` and `:drive_type` keys,
  or an empty list if the user is unknown or has no connected drives.
  """
  @spec load_enabled_drives(String.t()) :: [%{drive_id: String.t(), drive_type: String.t()}]
  def load_enabled_drives("unknown"), do: []

  def load_enabled_drives(user_id) do
    user_id
    |> Assistant.ConnectedDrives.enabled_for_user()
    |> Enum.map(fn d -> %{drive_id: d.drive_id, drive_type: d.drive_type} end)
  end
end
