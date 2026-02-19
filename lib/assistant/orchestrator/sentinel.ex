# lib/assistant/orchestrator/sentinel.ex — Context-isolated security gate.
#
# Checks proposed sub-agent actions before execution. In Phase 1 this is
# a no-op stub that always approves, but logs every check for the audit
# trail. Phase 2 will add a dedicated LLM call that evaluates whether
# irreversible actions (file deletion, email send, etc.) align with the
# original user request and agent mission.
#
# Related files:
#   - lib/assistant/orchestrator/sub_agent.ex (calls sentinel before each tool)
#   - lib/assistant/orchestrator/engine.ex (passes original_request context)

defmodule Assistant.Orchestrator.Sentinel do
  @moduledoc """
  Security gate for sub-agent actions.

  Every sub-agent tool call passes through the sentinel before execution.
  The sentinel evaluates whether the proposed action is appropriate given
  the original user request and the agent's declared mission.

  ## Phase 1 (Current)

  No-op stub — always returns `{:ok, :approved}`. Every check is logged
  for auditing and to validate the call pattern before Phase 2.

  ## Phase 2 (Planned)

  A dedicated LLM call (cheap, fast model) evaluates:
    - Does the action align with the user's original request?
    - Is the action within the agent's declared mission scope?
    - Is the action irreversible? If so, does it require user confirmation?
    - Are there content policy concerns?

  ## Contract

      check(original_request, agent_mission, proposed_action) ->
        {:ok, :approved}
        | {:ok, {:rejected, reason}}
  """

  require Logger

  @typedoc "A proposed action from a sub-agent."
  @type proposed_action :: %{
          skill_name: String.t(),
          arguments: map(),
          agent_id: String.t()
        }

  @doc """
  Check whether a proposed sub-agent action should be allowed.

  ## Parameters

    * `original_request` - The user's original message that triggered
      the orchestration turn
    * `agent_mission` - The mission string the orchestrator assigned
      to the sub-agent
    * `proposed_action` - Map describing the skill call:
      * `:skill_name` - The skill the agent wants to invoke
      * `:arguments` - The arguments it wants to pass
      * `:agent_id` - The agent making the request

  ## Returns

    * `{:ok, :approved}` - Action is safe to proceed
    * `{:ok, {:rejected, reason}}` - Action was blocked with explanation

  ## Phase 1 Behavior

  Always returns `{:ok, :approved}` with an info-level log entry.
  """
  @spec check(String.t() | nil, String.t(), proposed_action()) ::
          {:ok, :approved} | {:ok, {:rejected, String.t()}}
  def check(original_request, agent_mission, proposed_action) do
    Logger.info("Sentinel check (Phase 1 stub: approved)",
      agent_id: proposed_action[:agent_id],
      skill_name: proposed_action[:skill_name],
      mission_prefix: truncate(agent_mission, 80),
      request_prefix: truncate(original_request, 80)
    )

    {:ok, :approved}
  end

  # --- Private Helpers ---

  defp truncate(nil, _max), do: "(none)"
  defp truncate(text, max) when byte_size(text) <= max, do: text

  defp truncate(text, max) do
    String.slice(text, 0, max) <> "..."
  end
end
