# lib/assistant/orchestrator/sub_agent/skill_executor.ex — Skill dispatch for sub-agents.
#
# Handles the full chain for a single use_skill tool call: scope check →
# permission gate → sentinel security check → Google OAuth lazy auth →
# handler execution. Extracted from SubAgent to keep that GenServer focused
# on lifecycle management.
#
# Related files:
#   - lib/assistant/orchestrator/sub_agent/loop.ex (calls execute/3)
#   - lib/assistant/orchestrator/sentinel.ex (security gate)
#   - lib/assistant/skills/executor.ex (handler execution)
#   - lib/assistant/skills/registry.ex (skill lookup)

defmodule Assistant.Orchestrator.SubAgent.SkillExecutor do
  @moduledoc false

  alias Assistant.Auth.MagicLink
  alias Assistant.Integrations.Google.Auth, as: GoogleAuth
  alias Assistant.Orchestrator.{GoogleContext, LLMHelpers, Limits, Sentinel}
  alias Assistant.SkillPermissions
  alias Assistant.Skills.{Context, Executor, Registry, Result}

  require Logger

  # Google skill domains that require a per-user OAuth2 token.
  @google_skill_domains ~w(email calendar files)
  @default_timeout_ms 30_000

  @doc """
  Execute a single tool call, returning `{tool_call, result_content}`.

  Handles routing: use_skill calls go through the full validation chain,
  request_help returns a placeholder, unknown tools get an error message.
  """
  @spec execute(map(), map(), map()) :: {map(), String.t()}
  def execute(tc, dispatch_params, engine_state) do
    name = LLMHelpers.extract_function_name(tc)
    args = LLMHelpers.extract_function_args(tc)

    case name do
      "use_skill" ->
        execute_use_skill(tc, args, dispatch_params, engine_state)

      "request_help" ->
        # Handled upstream in Loop; this is a fallback
        {tc, "Request acknowledged. Waiting for orchestrator response."}

      other ->
        {tc, "Error: Unknown tool \"#{other}\". Only use_skill and request_help are available."}
    end
  end

  # --- use_skill Chain ---

  defp execute_use_skill(tc, args, dispatch_params, engine_state) do
    skill_name = args["skill"]
    skill_args = args["arguments"] || %{}

    cond do
      is_nil(skill_name) ->
        {tc, "Error: Missing required \"skill\" parameter in use_skill call."}

      not SkillPermissions.enabled?(skill_name) ->
        {tc, "Skill \"#{skill_name}\" is currently disabled by admin policy."}

      skill_name not in dispatch_params.skills ->
        Logger.warning("Sub-agent attempted out-of-scope skill",
          agent_id: dispatch_params.agent_id,
          skill: skill_name,
          allowed: dispatch_params.skills
        )

        {tc,
         "Error: Skill \"#{skill_name}\" is not available to this agent. " <>
           "Available skills: #{Enum.join(dispatch_params.skills, ", ")}"}

      true ->
        # Sentinel security gate
        proposed_action = %{
          skill_name: skill_name,
          arguments: skill_args,
          agent_id: dispatch_params.agent_id
        }

        original_request = engine_state[:original_request]

        case Sentinel.check(original_request, dispatch_params.mission, proposed_action) do
          {:ok, :approved} ->
            execute_skill_call(tc, skill_name, skill_args, dispatch_params, engine_state)

          {:ok, {:rejected, reason}} ->
            Logger.warning("Sentinel rejected sub-agent action",
              agent_id: dispatch_params.agent_id,
              skill: skill_name,
              reason: reason
            )

            {tc, "Action rejected by security gate: #{reason}"}
        end
    end
  end

  defp execute_skill_call(tc, skill_name, skill_args, dispatch_params, engine_state) do
    case Limits.check_skill(skill_name) do
      {:ok, :closed} ->
        case Registry.lookup(skill_name) do
          {:ok, skill_def} ->
            skill_context = build_skill_context(dispatch_params, engine_state)

            case maybe_require_google_auth(skill_name, skill_context, engine_state) do
              :ok ->
                case execute_handler(skill_def, skill_args, skill_context) do
                  {:ok, %Result{} = result} ->
                    Limits.record_skill_success(skill_name)
                    {tc, Result.truncate_content(result.content)}

                  {:error, reason} ->
                    Limits.record_skill_failure(skill_name)
                    {tc, "Skill execution failed: #{inspect(reason)}"}
                end

              {:needs_auth, magic_link_url} ->
                channel = engine_state[:channel]
                {tc, format_needs_auth_message(magic_link_url, channel)}

              {:needs_auth_rate_limited} ->
                {tc,
                 "Authorization already in progress. Please check your messages for the link."}
            end

          {:error, :not_found} ->
            {tc, "Error: Skill \"#{skill_name}\" not found in registry."}
        end

      {:error, :circuit_open} ->
        {tc,
         "Skill \"#{skill_name}\" is temporarily unavailable (circuit breaker open). " <>
           "Try a different approach or report this in your result."}
    end
  end

  # --- Google OAuth Lazy Auth ---

  defp maybe_require_google_auth(skill_name, skill_context, engine_state) do
    [domain | _] = String.split(skill_name, ".", parts: 2)

    if domain in @google_skill_domains and is_nil(skill_context.google_token) and
         GoogleAuth.oauth_configured?() do
      pending_intent = %{
        message: engine_state[:original_request] || "",
        conversation_id:
          engine_state[:parent_conversation_id] || engine_state[:conversation_id] || "",
        channel: to_string(engine_state[:channel] || "unknown"),
        reply_context: %{}
      }

      channel = to_string(engine_state[:channel] || "unknown")

      case MagicLink.generate(skill_context.user_id, channel, pending_intent) do
        {:ok, %{url: url}} ->
          {:needs_auth, url}

        {:error, :rate_limited} ->
          {:needs_auth_rate_limited}

        {:error, reason} ->
          Logger.error("Failed to generate magic link",
            user_id: skill_context.user_id,
            reason: inspect(reason)
          )

          :ok
      end
    else
      :ok
    end
  end

  # --- Auth Message Formatting ---

  defp format_needs_auth_message(magic_link_url, :google_chat) do
    """
    NEEDS_GOOGLE_AUTH: I need access to your Google account to complete this request.

    <#{magic_link_url}|Connect Google Account> (expires in 10 minutes)

    After connecting, your original request will be automatically resumed.\
    """
  end

  defp format_needs_auth_message(magic_link_url, :telegram) do
    """
    NEEDS_GOOGLE_AUTH: I need access to your Google account to complete this request.

    [Connect Google Account](#{magic_link_url}) (expires in 10 minutes)

    After connecting, your original request will be automatically resumed.\
    """
  end

  defp format_needs_auth_message(magic_link_url, _channel) do
    """
    NEEDS_GOOGLE_AUTH: I need access to your Google account to complete this request. \
    Please click the link below to connect your account (expires in 10 minutes):

    #{magic_link_url}

    After connecting, your original request will be automatically resumed.\
    """
  end

  # --- Handler Execution ---

  defp execute_handler(skill_def, flags, context) do
    case skill_def.handler do
      nil ->
        {:ok,
         %Result{
           status: :ok,
           content:
             "This is a template skill. Instructions:\n\n#{String.slice(skill_def.body, 0, 500)}"
         }}

      handler_module ->
        Executor.execute(handler_module, flags, context, timeout: @default_timeout_ms)
    end
  end

  # --- Skill Context ---

  defp build_skill_context(dispatch_params, engine_state) do
    root_conversation_id =
      engine_state[:parent_conversation_id] || engine_state[:conversation_id] || "unknown"

    user_id = engine_state[:user_id] || "unknown"
    google_token = resolve_google_token(user_id, dispatch_params.skills)

    %Context{
      conversation_id: root_conversation_id,
      execution_id: Ecto.UUID.generate(),
      user_id: user_id,
      channel: engine_state[:channel],
      integrations: Assistant.Integrations.Registry.default_integrations(),
      google_token: google_token,
      metadata: %{
        agent_id: dispatch_params.agent_id,
        root_conversation_id: root_conversation_id,
        agent_type: engine_state[:agent_type] || :orchestrator,
        google_token: GoogleContext.resolve_google_token(user_id),
        enabled_drives: GoogleContext.load_enabled_drives(user_id)
      }
    }
  end

  defp resolve_google_token(user_id, skills) when user_id != "unknown" do
    needs_google? =
      Enum.any?(skills, fn skill_name ->
        [domain | _] = String.split(skill_name, ".", parts: 2)
        domain in @google_skill_domains
      end)

    if needs_google? and GoogleAuth.oauth_configured?() do
      case GoogleAuth.user_token(user_id) do
        {:ok, access_token} ->
          access_token

        {:error, reason} when reason in [:not_connected, :refresh_failed] ->
          Logger.info("Google OAuth token not available for user",
            user_id: user_id,
            reason: reason
          )

          nil
      end
    else
      nil
    end
  end

  defp resolve_google_token(_user_id, _skills), do: nil
end
