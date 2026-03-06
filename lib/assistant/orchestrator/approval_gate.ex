# lib/assistant/orchestrator/approval_gate.ex — User approval gate for dangerous skills.
#
# Extracted from sub_agent.ex to keep the approval gate logic cohesive and
# testable independently. Called from the sub-agent's execute_use_skill path
# when a skill has requires_approval: true in its YAML frontmatter.
#
# The gate pauses the sub-agent's Task (via the existing {:loop_paused}
# mechanism) and blocks on a receive until the orchestrator sends a
# {:resume, %{approved: bool}} message through send_agent_update.
#
# Related files:
#   - lib/assistant/orchestrator/sub_agent.ex (calls into this module)
#   - lib/assistant/orchestrator/tools/send_agent_update.ex (sends resume)
#   - lib/assistant/skills/skill_definition.ex (requires_approval field)

defmodule Assistant.Orchestrator.ApprovalGate do
  @moduledoc """
  User approval gate for skills marked with `requires_approval: true`.

  When a sub-agent attempts to execute an approval-gated skill, this module
  pauses the agent and waits for the orchestrator to relay the user's decision
  via `send_agent_update(approved: true/false)`.

  ## Flow

  1. Sub-agent calls `use_skill` for an approval-gated skill
  2. `check/3` sends `{:loop_paused, reason, ...}` to the GenServer
  3. The Task blocks on `receive` waiting for `{:resume, update}`
  4. On approval: returns `:approved` so the caller can execute the skill
  5. On denial: returns `{:denied, feedback}` with a tool result message
  6. On timeout: returns `{:timeout, message}` with a timeout message
  """

  require Logger

  # Maximum time to wait for user approval before auto-cancelling.
  @approval_timeout_ms 300_000

  @doc """
  Check the approval gate for a skill. If the skill requires approval,
  pauses the sub-agent and waits for the orchestrator's decision.

  ## Parameters

    * `skill_name` - The skill being executed (e.g., "email.send")
    * `skill_args` - The arguments the LLM provided for the skill
    * `opts` - Keyword list with:
      * `:skill_def` - The SkillDefinition struct
      * `:dispatch_params` - Sub-agent dispatch parameters
      * `:genserver_pid` - The sub-agent GenServer pid
      * `:approval_index` - Optional `{current, total}` for batch tracking

  ## Returns

    * `:approved` - User approved; caller should execute the skill
    * `{:denied, feedback_message}` - User denied; message for the LLM
    * `{:timeout, timeout_message}` - Approval timed out; message for the LLM
  """
  @spec check(String.t(), map(), keyword()) ::
          :approved | {:denied, String.t()} | {:timeout, String.t()}
  def check(skill_name, skill_args, opts) do
    skill_def = Keyword.fetch!(opts, :skill_def)
    dispatch_params = Keyword.fetch!(opts, :dispatch_params)
    genserver_pid = Keyword.fetch!(opts, :genserver_pid)
    approval_index = Keyword.get(opts, :approval_index)

    reason = build_approval_reason(skill_name, skill_args, skill_def, approval_index)

    # Synthetic tool_call_id for the pause mechanism. Uses a monotonic integer
    # rather than UUID format because this ID is only used internally by the
    # GenServer's pending_help_tc tracking — no downstream code validates it
    # as a UUID.
    synthetic_tc = %{id: "approval_#{System.unique_integer([:positive])}"}
    agent_id = dispatch_params.agent_id
    start_time = System.monotonic_time(:millisecond)

    Logger.info("Approval gate triggered — pausing sub-agent",
      agent_id: agent_id,
      skill: skill_name
    )

    :telemetry.execute(
      [:assistant, :approval_gate, :requested],
      %{system_time: System.system_time()},
      %{skill: skill_name, agent_id: agent_id}
    )

    # Pause using existing {:loop_paused} mechanism
    send(genserver_pid, {:loop_paused, reason, nil, synthetic_tc})

    # Block until orchestrator resumes via send_agent_update(approved: bool)
    receive do
      {:resume, %{approved: true}} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time

        :telemetry.execute(
          [:assistant, :approval_gate, :approved],
          %{duration: duration_ms},
          %{skill: skill_name, agent_id: agent_id}
        )

        :approved

      {:resume, %{approved: false, message: feedback}} when is_binary(feedback) ->
        duration_ms = System.monotonic_time(:millisecond) - start_time

        :telemetry.execute(
          [:assistant, :approval_gate, :denied],
          %{duration: duration_ms},
          %{skill: skill_name, agent_id: agent_id, has_feedback: true}
        )

        {:denied,
         "APPROVAL_DENIED: User requested changes: #{feedback}\n\n" <>
           "Adjust your approach based on the feedback and try again."}

      {:resume, %{approved: false}} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time

        :telemetry.execute(
          [:assistant, :approval_gate, :denied],
          %{duration: duration_ms},
          %{skill: skill_name, agent_id: agent_id, has_feedback: false}
        )

        {:denied, "APPROVAL_DENIED: User cancelled this action."}

      {:resume, _update} ->
        # Catches resume messages without the `approved` field — e.g., a plain
        # message update from the orchestrator that wasn't intended as an approval
        # response. Default to safe cancellation to avoid executing without
        # explicit user consent.
        duration_ms = System.monotonic_time(:millisecond) - start_time

        :telemetry.execute(
          [:assistant, :approval_gate, :denied],
          %{duration: duration_ms},
          %{skill: skill_name, agent_id: agent_id, has_feedback: false}
        )

        {:denied, "APPROVAL_DENIED: Approval response was unclear. Action not executed."}
    after
      @approval_timeout_ms ->
        Logger.warning("Approval gate timed out after #{div(@approval_timeout_ms, 1_000)}s",
          agent_id: agent_id,
          skill: skill_name
        )

        :telemetry.execute(
          [:assistant, :approval_gate, :timeout],
          %{duration: @approval_timeout_ms},
          %{skill: skill_name, agent_id: agent_id}
        )

        {:timeout,
         "Approval request timed out (#{div(@approval_timeout_ms, 60_000)} minutes). " <>
           "The action was not executed."}
    end
  end

  @doc """
  Builds the approval reason string shown to the orchestrator/user.

  Includes the skill name, all parameter values, and an optional batch
  position indicator (e.g., "Action 1 of 3 requiring approval").
  """
  @spec build_approval_reason(String.t(), map(), struct(), {pos_integer(), pos_integer()} | nil) ::
          String.t()
  def build_approval_reason(skill_name, skill_args, skill_def, approval_index \\ nil) do
    args_text =
      skill_def.parameters
      |> Enum.map(fn param ->
        param_name = param[:name] || param["name"]
        value = Map.get(skill_args, param_name, "(not provided)")
        "  #{param_name}: #{format_value(value)}"
      end)
      |> Enum.join("\n")

    # Fall back to raw args if no parameters are defined in the skill
    args_text =
      if args_text == "" and map_size(skill_args) > 0 do
        skill_args
        |> Enum.map(fn {k, v} -> "  #{k}: #{format_value(v)}" end)
        |> Enum.join("\n")
      else
        args_text
      end

    batch_note =
      case approval_index do
        {current, total} when total > 1 ->
          "\n\nNote: Action #{current} of #{total} requiring approval in this batch."

        _ ->
          ""
      end

    "[APPROVAL_REQUIRED] Skill \"#{skill_name}\" requires user approval.\n\n" <>
      "Proposed action:\n#{args_text}" <>
      batch_note
  end

  # Format a value for display in the approval reason. Uses inspect for
  # non-string values (maps, lists) to produce readable output rather than
  # crashing on Protocol.String not implemented.
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: inspect(value)
end
