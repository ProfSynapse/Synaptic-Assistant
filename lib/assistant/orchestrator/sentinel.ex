# lib/assistant/orchestrator/sentinel.ex — Context-isolated security gate.
#
# Checks proposed sub-agent actions before execution. Makes a lightweight LLM
# classification call to evaluate whether the action aligns with the user's
# original request and the agent's declared mission. Fails open on LLM errors
# (returns approved with a warning log) since scope enforcement in sub_agent.ex
# is the primary security boundary.
#
# Related files:
#   - lib/assistant/orchestrator/sub_agent.ex (calls sentinel before each tool)
#   - lib/assistant/orchestrator/engine.ex (passes original_request context)
#   - lib/assistant/integrations/openrouter.ex (LLM client for classification)
#   - lib/assistant/config/loader.ex (model selection for sentinel tier)

defmodule Assistant.Orchestrator.Sentinel do
  @moduledoc """
  Security gate for sub-agent actions.

  Every sub-agent tool call passes through the sentinel before execution.
  The sentinel makes a lightweight LLM classification call (sentinel-tier
  model) to evaluate whether the proposed action aligns with the user's
  original request and the agent's declared mission.

  ## Evaluation Axes

    * **Request alignment** — Does this action serve what the user asked for?
    * **Mission scope** — Is this action within what the agent was assigned to do?

  ## Risk Model

    * Read-only actions (search, list, get, read) — low risk, approve if loosely related
    * Prerequisite steps — valid workflow (searching before the main action)
    * State-modifying actions (create, update, send, delete) — require clear alignment
    * Irreversible actions (email.send, files.archive) — require strong alignment

  ## Error Handling

  Fails open on LLM errors — returns `{:ok, :approved}` with a warning log.
  The sentinel is a defense-in-depth layer; scope enforcement in
  `sub_agent.ex` (skill allow-list check) is the primary security boundary.

  ## Contract

      check(original_request, agent_mission, proposed_action) ->
        {:ok, :approved}
        | {:ok, {:rejected, reason}}
  """

  require Logger

  alias Assistant.Config.Loader, as: ConfigLoader

  @llm_client Application.compile_env(
                :assistant,
                :llm_client,
                Assistant.Integrations.OpenRouter
              )

  @sentinel_prompt """
  You are a security gate for an AI assistant's sub-agent system. Your role is to evaluate whether a proposed action aligns with the user's original request and the agent's declared mission.

  You receive three inputs:
  1. ORIGINAL REQUEST: What the user actually asked for
  2. AGENT MISSION: The task the orchestrator assigned to this agent
  3. PROPOSED ACTION: The specific skill call the agent wants to make (skill name + arguments)

  Evaluate alignment on two axes:
  - REQUEST ALIGNMENT: Does this action serve what the user asked for?
  - MISSION SCOPE: Is this action within what the agent was assigned to do?

  Key reasoning principles:
  - Read-only actions (search, list, get, read) are low risk — approve if even loosely related
  - Prerequisite steps are valid: searching for info before the main action is normal workflow
  - State-modifying actions (create, update, send, delete, archive) require clear alignment
  - Irreversible actions (email.send, files.archive) require strong alignment
  - An agent should not perform actions outside its mission domain, even if the user might want it — the orchestrator handles cross-domain coordination
  - If the original request is missing (null), evaluate against mission scope only
  """

  @sentinel_response_format %{
    type: "json_schema",
    json_schema: %{
      name: "sentinel_decision",
      strict: true,
      schema: %{
        type: "object",
        properties: %{
          decision: %{
            type: "string",
            enum: ["approve", "reject"],
            description: "Whether to approve or reject the proposed action"
          },
          reason: %{
            type: "string",
            description: "One-line explanation for the decision"
          }
        },
        required: ["decision", "reason"],
        additionalProperties: false
      }
    }
  }

  @hardcoded_fallback_model "openai/gpt-5-mini"

  @typedoc "A proposed action from a sub-agent."
  @type proposed_action :: %{
          skill_name: String.t(),
          arguments: map(),
          agent_id: String.t()
        }

  @doc """
  Check whether a proposed sub-agent action should be allowed.

  Makes a lightweight LLM classification call to evaluate alignment between
  the proposed action, the user's original request, and the agent's mission.

  ## Parameters

    * `original_request` - The user's original message that triggered
      the orchestration turn (may be `nil`)
    * `agent_mission` - The mission string the orchestrator assigned
      to the sub-agent
    * `proposed_action` - Map describing the skill call:
      * `:skill_name` - The skill the agent wants to invoke
      * `:arguments` - The arguments it wants to pass
      * `:agent_id` - The agent making the request

  ## Returns

    * `{:ok, :approved}` - Action is safe to proceed
    * `{:ok, {:rejected, reason}}` - Action was blocked with explanation

  ## Error Handling

  If the LLM call fails for any reason (network error, rate limit, timeout,
  malformed response), the sentinel fails open and returns `{:ok, :approved}`
  with a warning log. This maintains availability since scope enforcement in
  `sub_agent.ex` is the primary security boundary.
  """
  @spec check(String.t() | nil, String.t(), proposed_action()) ::
          {:ok, :approved} | {:ok, {:rejected, String.t()}}
  def check(original_request, agent_mission, proposed_action) do
    model = resolve_sentinel_model()
    messages = build_messages(original_request, agent_mission, proposed_action)

    Logger.info("Sentinel check",
      agent_id: proposed_action[:agent_id],
      skill_name: proposed_action[:skill_name],
      mission_prefix: truncate(agent_mission, 80),
      request_prefix: truncate(original_request, 80)
    )

    case @llm_client.chat_completion(messages,
           model: model,
           temperature: 0.0,
           max_tokens: 150,
           response_format: @sentinel_response_format
         ) do
      {:ok, %{content: content}} ->
        case parse_decision(content) do
          {:ok, :approved, reason} ->
            Logger.info("Sentinel approved",
              agent_id: proposed_action[:agent_id],
              skill_name: proposed_action[:skill_name],
              reason: reason
            )

            {:ok, :approved}

          {:ok, :rejected, reason} ->
            Logger.warning("Sentinel rejected",
              agent_id: proposed_action[:agent_id],
              skill_name: proposed_action[:skill_name],
              reason: reason
            )

            {:ok, {:rejected, reason}}

          {:error, parse_reason} ->
            Logger.warning("Sentinel response parse failed, approving (fail-open)",
              agent_id: proposed_action[:agent_id],
              skill_name: proposed_action[:skill_name],
              content: content,
              reason: inspect(parse_reason)
            )

            {:ok, :approved}
        end

      {:error, reason} ->
        Logger.warning("Sentinel LLM call failed, approving (fail-open)",
          agent_id: proposed_action[:agent_id],
          skill_name: proposed_action[:skill_name],
          model: model,
          reason: inspect(reason)
        )

        {:ok, :approved}
    end
  end

  # --- Message Building ---

  defp build_messages(original_request, agent_mission, proposed_action) do
    args_json =
      case Jason.encode(proposed_action[:arguments] || %{}) do
        {:ok, json} -> json
        {:error, _} -> inspect(proposed_action[:arguments] || %{})
      end

    user_content = """
    ORIGINAL REQUEST: #{original_request || "(none)"}

    AGENT MISSION: #{agent_mission}

    PROPOSED ACTION:
      Skill: #{proposed_action[:skill_name]}
      Arguments: #{args_json}
      Agent ID: #{proposed_action[:agent_id]}

    Evaluate whether this action should be approved or rejected.\
    """

    [
      %{role: "system", content: @sentinel_prompt},
      %{role: "user", content: user_content}
    ]
  end

  # --- Response Parsing ---

  defp parse_decision(content) when is_binary(content) do
    # Strip markdown code fences if present (defensive, should not be needed
    # with json_schema strict mode)
    cleaned =
      content
      |> String.trim()
      |> String.replace(~r/^```json\s*/, "")
      |> String.replace(~r/\s*```$/, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, %{"decision" => "approve", "reason" => reason}} ->
        {:ok, :approved, reason}

      {:ok, %{"decision" => "reject", "reason" => reason}} ->
        {:ok, :rejected, reason}

      {:ok, %{"decision" => other}} ->
        {:error, {:invalid_decision, other}}

      {:error, decode_error} ->
        {:error, {:json_decode_failed, decode_error}}
    end
  end

  defp parse_decision(_), do: {:error, :nil_content}

  # --- Model Resolution ---

  defp resolve_sentinel_model do
    case ConfigLoader.model_for(:sentinel) do
      %{id: id} ->
        id

      nil ->
        case ConfigLoader.model_for(:compaction) do
          %{id: id} -> id
          nil -> @hardcoded_fallback_model
        end
    end
  rescue
    _error ->
      Logger.warning("ConfigLoader unavailable for sentinel model, using hardcoded fallback")
      @hardcoded_fallback_model
  end

  # --- Private Helpers ---

  defp truncate(nil, _max), do: "(none)"
  defp truncate(text, max) when byte_size(text) <= max, do: text

  defp truncate(text, max) do
    String.slice(text, 0, max) <> "..."
  end
end
