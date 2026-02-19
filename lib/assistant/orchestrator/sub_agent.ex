# lib/assistant/orchestrator/sub_agent.ex — GenServer-based sub-agent execution engine.
#
# Each sub-agent runs as a GenServer registered in Assistant.SubAgent.Registry.
# The LLM loop runs in a Task.async linked to the GenServer, sending messages
# back as progress events. This enables the sub-agent to pause (transition to
# :awaiting_orchestrator) when it calls the `request_help` tool, and resume
# when the orchestrator sends new context via `send_agent_update`.
#
# States: :running | :awaiting_orchestrator | :completed | :failed
#
# Related files:
#   - lib/assistant/orchestrator/engine.ex (spawns sub-agents via scheduler)
#   - lib/assistant/orchestrator/agent_scheduler.ex (DAG execution)
#   - lib/assistant/orchestrator/sentinel.ex (security gate for each tool call)
#   - lib/assistant/orchestrator/limits.ex (budget enforcement)
#   - lib/assistant/skills/executor.ex (runs skill handlers)
#   - lib/assistant/skills/registry.ex (skill definition lookup)
#   - lib/assistant/behaviours/llm_client.ex (LLM call contract)
#   - lib/assistant/config/prompt_loader.ex (sub-agent system prompt template)

defmodule Assistant.Orchestrator.SubAgent do
  @moduledoc """
  GenServer execution engine for sub-agents dispatched by the orchestrator.

  Each sub-agent runs its own short LLM loop with a scoped tool surface.
  The sub-agent only sees `use_skill` and `request_help` tools, where
  `use_skill`'s `skill` parameter is restricted to the skills the
  orchestrator granted via `dispatch_agent`.

  ## Lifecycle

  1. `start_link/1` — starts the GenServer, registers in SubAgent.Registry
  2. The GenServer spawns a Task that runs the LLM loop
  3. If LLM returns text -> done (`:completed`)
  4. If LLM returns `use_skill` calls -> validate scope -> sentinel check ->
     execute via Executor -> feed results back to LLM -> loop
  5. If LLM returns `request_help` call -> transition to `:awaiting_orchestrator`
  6. `resume/2` — orchestrator sends update, task resumes LLM loop
  7. If tool budget exhausted -> `:completed` with partial result
  8. If LLM error -> `:failed`

  ## States

    * `:running` — LLM loop is actively processing
    * `:awaiting_orchestrator` — paused, waiting for orchestrator update
    * `:completed` — terminal, mission finished or budget exhausted
    * `:failed` — terminal, unrecoverable error

  ## Scope Enforcement

  The `use_skill` tool definition includes an `enum` restricting the skill
  name to only the skills the orchestrator granted. This is enforced at both
  the tool definition level (LLM sees the enum) and at runtime (the executor
  validates against the allowed list).

  ## Configuration

  The LLM client is injected via `Application.compile_env/3` for testability
  with Mox.
  """

  use GenServer

  alias Assistant.Analytics
  alias Assistant.Config.{Loader, PromptLoader}
  alias Assistant.Orchestrator.{LLMHelpers, Limits, Sentinel}
  alias Assistant.SkillPermissions
  alias Assistant.Skills.{Context, Executor, Registry, Result}

  require Logger

  @llm_client Application.compile_env(
                :assistant,
                :llm_client,
                Assistant.Integrations.OpenRouter
              )

  @default_max_tool_calls 5
  @default_timeout_ms 30_000

  # --- Client API ---

  @doc """
  Start a sub-agent GenServer process.

  ## Parameters

    * `opts` - Keyword list with:
      * `:dispatch_params` - Map from dispatch_agent with mission, skills, etc.
      * `:dep_results` - Map of agent_id => result from dependency agents
      * `:engine_state` - Map with conversation_id, user_id, etc.

  ## Returns

    * `{:ok, pid}` on success (agent_id available via get_status/1)
    * `{:error, reason}` on failure
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    dispatch_params = Keyword.fetch!(opts, :dispatch_params)
    agent_id = dispatch_params.agent_id

    GenServer.start_link(__MODULE__, opts, name: via_tuple(agent_id))
  end

  @doc """
  Get the current status and result of a sub-agent.

  ## Parameters

    * `agent_id` - The sub-agent's identifier

  ## Returns

    * `{:ok, status_map}` with keys: `:status`, `:result`, `:tool_calls_used`,
      `:duration_ms`, `:reason` (for awaiting_orchestrator), `:partial_history`
    * `{:error, :not_found}` if agent is not registered
  """
  @spec get_status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_status(agent_id) do
    GenServer.call(via_tuple(agent_id), :get_status)
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
  end

  @doc """
  Resume a paused sub-agent with an orchestrator update.

  The sub-agent must be in `:awaiting_orchestrator` state. The update
  is injected as a tool result for the pending `request_help` call,
  and the LLM loop resumes.

  ## Parameters

    * `agent_id` - The sub-agent's identifier
    * `update` - Map with orchestrator response, e.g.:
      * `:message` - Text response/instructions from orchestrator
      * `:skills` - Optional list of new skill names to add
      * `:context_files` - Optional list of new context file paths

  ## Returns

    * `:ok` if agent was paused and is now resuming
    * `{:error, :not_awaiting}` if agent is not in awaiting state
    * `{:error, :not_found}` if agent is not registered
  """
  @spec resume(String.t(), map()) :: :ok | {:error, :not_awaiting | :not_found}
  def resume(agent_id, update) do
    GenServer.call(via_tuple(agent_id), {:resume, update})
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
  end

  @doc """
  Synchronous execute for backward compatibility and simpler callers.

  Starts the GenServer, waits for completion (up to timeout), and returns
  the final result map. This is the interface the AgentScheduler uses.

  ## Parameters

    * `dispatch_params` - Map with mission, skills, context, etc. from dispatch_agent
    * `dep_results` - Map of agent_id => result from dependency agents
    * `engine_state` - Map with conversation_id, user_id, etc. from the Engine

  ## Returns

  A map with:
    * `:status` - `:completed`, `:failed`, `:timeout`, or `:awaiting_orchestrator`
    * `:result` - Human-readable summary of what was accomplished
    * `:tool_calls_used` - Number of skill calls executed
    * `:duration_ms` - Wall-clock execution time

  Or `{:error, {:context_budget_exceeded, details}}` if context files
  exceed the model's token budget.
  """
  @spec execute(map(), map(), map()) ::
          map() | {:error, {:context_budget_exceeded, map()}}
  def execute(dispatch_params, dep_results, engine_state) do
    agent_id = dispatch_params.agent_id

    opts = [
      dispatch_params: dispatch_params,
      dep_results: dep_results,
      engine_state: engine_state
    ]

    case start_link(opts) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        wait_for_completion(agent_id, ref)

      {:error, reason} ->
        %{
          status: :failed,
          result: "Failed to start sub-agent: #{inspect(reason)}",
          tool_calls_used: 0,
          duration_ms: 0
        }
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    dispatch_params = Keyword.fetch!(opts, :dispatch_params)
    dep_results = Keyword.get(opts, :dep_results, %{})
    engine_state = Keyword.get(opts, :engine_state, %{})

    agent_id = dispatch_params.agent_id
    started_at = System.monotonic_time(:millisecond)

    # Each sub-agent gets its own conversation_id. The orchestrator's
    # conversation_id becomes the parent (root) for memory unification.
    sub_conversation_id = Ecto.UUID.generate()
    parent_conversation_id = engine_state[:conversation_id]

    sub_engine_state =
      engine_state
      |> Map.put(:conversation_id, sub_conversation_id)
      |> Map.put(:parent_conversation_id, parent_conversation_id)
      |> Map.put(:agent_type, :sub_agent)

    Logger.info("Sub-agent starting",
      agent_id: agent_id,
      skills: dispatch_params.skills,
      conversation_id: sub_conversation_id,
      parent_conversation_id: parent_conversation_id
    )

    state = %{
      agent_id: agent_id,
      dispatch_params: dispatch_params,
      dep_results: dep_results,
      engine_state: sub_engine_state,
      started_at: started_at,
      status: :running,
      result: nil,
      tool_calls_used: 0,
      duration_ms: nil,
      # Pause/resume state
      awaiting_reason: nil,
      awaiting_partial_history: nil,
      pending_help_tc: nil,
      # The Task running the LLM loop
      loop_task: nil,
      loop_ref: nil
    }

    # Start the LLM loop in the next tick so init returns fast
    {:ok, state, {:continue, :start_loop}}
  end

  @impl true
  def handle_continue(:start_loop, state) do
    case build_context(state.dispatch_params, state.dep_results, state.engine_state) do
      {:error, {:context_budget_exceeded, _details}} = error ->
        Logger.warning("Sub-agent aborted — context files exceed token budget",
          agent_id: state.agent_id,
          conversation_id: state.engine_state[:conversation_id]
        )

        # Store the error and terminate. The caller (execute/3) will detect
        # the DOWN message and extract the error from process state.
        final_state = %{state | status: :failed, result: error}
        {:stop, {:shutdown, error}, final_state}

      {:ok, context} ->
        max_calls = state.dispatch_params[:max_tool_calls] || @default_max_tool_calls
        agent_limit_state = Limits.new_agent_state(max_skill_calls: max_calls)

        # Spawn the LLM loop as a linked Task
        parent = self()

        task =
          Task.async(fn ->
            run_loop(
              context,
              agent_limit_state,
              state.dispatch_params,
              state.engine_state,
              parent
            )
          end)

        {:noreply, %{state | loop_task: task, loop_ref: task.ref}}
    end
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status_map = %{
      status: state.status,
      result: extract_result_text(state.result),
      tool_calls_used: state.tool_calls_used,
      duration_ms: state.duration_ms || elapsed_ms(state.started_at)
    }

    status_map =
      if state.status == :awaiting_orchestrator do
        status_map
        |> Map.put(:reason, state.awaiting_reason)
        |> Map.put(:partial_history, state.awaiting_partial_history)
      else
        status_map
      end

    {:reply, {:ok, status_map}, state}
  end

  @impl true
  def handle_call({:resume, update}, _from, state) do
    if state.status != :awaiting_orchestrator do
      {:reply, {:error, :not_awaiting}, state}
    else
      Logger.info("Sub-agent resuming after orchestrator update",
        agent_id: state.agent_id,
        has_new_skills: update[:skills] != nil,
        has_message: update[:message] != nil
      )

      # Send the resume signal to the loop task (it's waiting on receive)
      send(state.loop_task.pid, {:resume, update})

      {:reply, :ok,
       %{state | status: :running, awaiting_reason: nil, awaiting_partial_history: nil}}
    end
  end

  @impl true
  def handle_info({:loop_paused, reason, partial_history, help_tc}, state) do
    Logger.info("Sub-agent paused — awaiting orchestrator",
      agent_id: state.agent_id,
      reason: reason
    )

    {:noreply,
     %{
       state
       | status: :awaiting_orchestrator,
         awaiting_reason: reason,
         awaiting_partial_history: partial_history,
         pending_help_tc: help_tc
     }}
  end

  @impl true
  def handle_info({:tool_calls_update, count}, state) do
    {:noreply, %{state | tool_calls_used: count}}
  end

  @impl true
  def handle_info({ref, result}, %{loop_ref: ref} = state) do
    # Task completed normally
    Process.demonitor(ref, [:flush])

    duration_ms = elapsed_ms(state.started_at)

    final_result =
      case result do
        %{status: _} = map ->
          Map.put(map, :duration_ms, duration_ms)

        other ->
          %{
            status: :completed,
            result: other,
            tool_calls_used: state.tool_calls_used,
            duration_ms: duration_ms
          }
      end

    Logger.info("Sub-agent completed",
      agent_id: state.agent_id,
      status: final_result.status,
      tool_calls_used: final_result[:tool_calls_used] || state.tool_calls_used,
      duration_ms: duration_ms,
      conversation_id: state.engine_state[:conversation_id],
      parent_conversation_id: state.engine_state[:parent_conversation_id]
    )

    final_state = %{
      state
      | status: final_result.status,
        result: final_result.result,
        tool_calls_used: final_result[:tool_calls_used] || state.tool_calls_used,
        duration_ms: duration_ms
    }

    # Use {:shutdown, result_map} so wait_for_completion can extract the
    # final result from the :DOWN message — the GenServer is dead before
    # get_status can be called.
    {:stop, {:shutdown, build_final_result_map(final_state)}, final_state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{loop_ref: ref} = state) do
    # Task crashed
    duration_ms = elapsed_ms(state.started_at)

    Logger.error("Sub-agent loop task crashed",
      agent_id: state.agent_id,
      reason: inspect(reason)
    )

    final_state = %{
      state
      | status: :failed,
        result: "Sub-agent loop crashed: #{inspect(reason)}",
        duration_ms: duration_ms
    }

    {:stop, {:shutdown, build_final_result_map(final_state)}, final_state}
  end

  # Catch-all for unrelated messages
  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- LLM Loop (runs in Task) ---

  defp run_loop(context, agent_state, dispatch_params, engine_state, genserver_pid) do
    model_opts = build_model_opts(dispatch_params, context)
    model = Keyword.get(model_opts, :model)

    case @llm_client.chat_completion(context.messages, model_opts) do
      {:ok, response} ->
        record_llm_analytics(engine_state, response, model, :ok)

        handle_response(
          response,
          context,
          agent_state,
          dispatch_params,
          engine_state,
          genserver_pid
        )

      {:error, reason} ->
        record_llm_analytics(engine_state, nil, model, :error, reason)

        Logger.error("Sub-agent LLM call failed",
          agent_id: dispatch_params.agent_id,
          reason: inspect(reason),
          conversation_id: engine_state[:conversation_id]
        )

        %{
          status: :failed,
          result: "LLM call failed: #{inspect(reason)}",
          tool_calls_used: agent_state.skill_calls
        }
    end
  end

  defp handle_response(
         response,
         context,
         agent_state,
         dispatch_params,
         engine_state,
         genserver_pid
       ) do
    cond do
      # Text response — mission complete
      has_text_no_tools?(response) ->
        %{
          status: :completed,
          result: response.content,
          tool_calls_used: agent_state.skill_calls
        }

      # Tool calls — execute and loop
      has_tool_calls?(response) ->
        execute_tool_calls(
          response.tool_calls,
          response,
          context,
          agent_state,
          dispatch_params,
          engine_state,
          genserver_pid
        )

      # Fallback: empty response
      true ->
        %{
          status: :completed,
          result: response[:content] || "Agent completed with no output.",
          tool_calls_used: agent_state.skill_calls
        }
    end
  end

  defp execute_tool_calls(
         tool_calls,
         _response,
         context,
         agent_state,
         dispatch_params,
         engine_state,
         genserver_pid
       ) do
    call_count = length(tool_calls)

    case Limits.check_agent(agent_state, call_count) do
      {:ok, new_agent_state} ->
        # Check for request_help tool call first
        {help_calls, skill_calls} =
          Enum.split_with(tool_calls, fn tc ->
            extract_function_name(tc) == "request_help"
          end)

        # Execute skill calls
        {results, final_agent_state} =
          Enum.map_reduce(skill_calls, new_agent_state, fn tc, acc_state ->
            result = execute_single_tool(tc, dispatch_params, engine_state)
            {result, acc_state}
          end)

        # Report tool call count back to GenServer
        send(genserver_pid, {:tool_calls_update, final_agent_state.skill_calls})

        # Build messages: assistant tool_calls + tool results
        assistant_msg = %{role: "assistant", tool_calls: tool_calls}

        tool_msgs =
          Enum.map(results, fn {tc, result_content} ->
            %{role: "tool", tool_call_id: tc.id, content: result_content}
          end)

        new_messages = context.messages ++ [assistant_msg | tool_msgs]

        # If there was a request_help call, pause and wait for orchestrator
        case help_calls do
          [help_tc | _] ->
            help_args = extract_function_args(help_tc)
            reason = help_args["reason"] || "Sub-agent requests assistance"
            partial_results = help_args["partial_results"]

            # Notify GenServer we're pausing
            send(genserver_pid, {:loop_paused, reason, partial_results, help_tc})

            # Block until orchestrator sends resume (5 min timeout)
            receive do
              {:resume, update} ->
                # Inject orchestrator response as tool result for request_help
                resume_content = build_resume_content(update, dispatch_params)

                help_result_msg = %{
                  role: "tool",
                  tool_call_id: help_tc.id,
                  content: resume_content
                }

                # If new skills were added, inject their definitions as a user message
                skill_injection_msgs = build_skill_injection_messages(update)

                resumed_messages = new_messages ++ [help_result_msg | skill_injection_msgs]

                # Update dispatch_params with any new skills
                updated_dispatch = maybe_add_skills(dispatch_params, update[:skills])

                updated_context =
                  update_context_with_new_tools(context, resumed_messages, updated_dispatch)

                run_loop(
                  updated_context,
                  final_agent_state,
                  updated_dispatch,
                  engine_state,
                  genserver_pid
                )

              {:shutdown, reason} ->
                %{
                  status: :failed,
                  result: "Sub-agent shut down while awaiting orchestrator: #{inspect(reason)}",
                  tool_calls_used: final_agent_state.skill_calls
                }
            after
              300_000 ->
                Logger.warning("Sub-agent resume timeout after 5 minutes",
                  agent_id: dispatch_params.agent_id
                )

                %{
                  status: :failed,
                  result: "Timed out waiting for orchestrator response (5 minutes).",
                  tool_calls_used: final_agent_state.skill_calls
                }
            end

          [] ->
            # No request_help — continue the loop normally
            new_context = %{context | messages: new_messages}
            run_loop(new_context, final_agent_state, dispatch_params, engine_state, genserver_pid)
        end

      {:error, :limit_exceeded, _details} ->
        Logger.info("Sub-agent tool budget exhausted",
          agent_id: dispatch_params.agent_id,
          used: agent_state.skill_calls,
          max: agent_state.max_skill_calls
        )

        last_text = extract_last_text(context.messages)

        %{
          status: :completed,
          result:
            last_text ||
              "Tool call limit reached (#{agent_state.skill_calls}/#{agent_state.max_skill_calls}). " <>
                "Partial work completed.",
          tool_calls_used: agent_state.skill_calls
        }
    end
  end

  defp execute_single_tool(tc, dispatch_params, engine_state) do
    name = extract_function_name(tc)
    args = extract_function_args(tc)

    case name do
      "use_skill" ->
        execute_use_skill(tc, args, dispatch_params, engine_state)

      "request_help" ->
        # Handled upstream in execute_tool_calls; this is a fallback
        {tc, "Request acknowledged. Waiting for orchestrator response."}

      other ->
        {tc, "Error: Unknown tool \"#{other}\". Only use_skill and request_help are available."}
    end
  end

  defp execute_use_skill(tc, args, dispatch_params, engine_state) do
    skill_name = args["skill"]
    skill_args = args["arguments"] || %{}

    # Scope enforcement: only allowed skills
    if not SkillPermissions.enabled?(skill_name) do
      {tc, "Skill \"#{skill_name}\" is currently disabled by admin policy."}
    else
      if skill_name in dispatch_params.skills do
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
      else
        Logger.warning("Sub-agent attempted out-of-scope skill",
          agent_id: dispatch_params.agent_id,
          skill: skill_name,
          allowed: dispatch_params.skills
        )

        {tc,
         "Error: Skill \"#{skill_name}\" is not available to this agent. " <>
           "Available skills: #{Enum.join(dispatch_params.skills, ", ")}"}
      end
    end
  end

  defp execute_skill_call(tc, skill_name, skill_args, dispatch_params, engine_state) do
    # Level 1: Check skill circuit breaker
    case Limits.check_skill(skill_name) do
      {:ok, :closed} ->
        # Look up the skill and execute
        case Registry.lookup(skill_name) do
          {:ok, skill_def} ->
            skill_context = build_skill_context(dispatch_params, engine_state)

            case execute_handler(skill_def, skill_args, skill_context) do
              {:ok, %Result{} = result} ->
                Limits.record_skill_success(skill_name)
                {tc, result.content}

              {:error, reason} ->
                Limits.record_skill_failure(skill_name)
                {tc, "Skill execution failed: #{inspect(reason)}"}
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

  defp execute_handler(skill_def, flags, context) do
    case skill_def.handler do
      nil ->
        # Template/custom skill with no handler — return the body as guidance
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

  # --- Context Building ---

  defp build_context(dispatch_params, dep_results, _engine_state) do
    case build_system_prompt(dispatch_params, dep_results) do
      {:error, _} = error ->
        error

      {:ok, system_prompt} ->
        tools = build_scoped_tools(dispatch_params.skills)
        mission_msg = %{role: "user", content: dispatch_params.mission}

        {:ok,
         %{
           system_prompt: system_prompt,
           messages: [%{role: "system", content: system_prompt}, mission_msg],
           tools: tools,
           allowed_skills: dispatch_params.skills
         }}
    end
  end

  defp build_system_prompt(dispatch_params, dep_results) do
    skills_text = Enum.join(dispatch_params.skills, ", ")
    dep_section = build_dependency_section(dep_results)
    context_section = build_context_section(dispatch_params.context)
    skill_definitions_section = build_skill_definitions_section(dispatch_params.skills)

    assigns = %{
      skills_text: skills_text,
      dep_section: dep_section,
      context_section: context_section
    }

    base_prompt =
      case PromptLoader.render(:sub_agent, assigns) do
        {:ok, rendered} ->
          rendered

        {:error, _reason} ->
          # Fallback: hardcoded prompt if YAML not loaded
          Logger.warning("PromptLoader fallback for :sub_agent — using hardcoded prompt")

          """
          You are a focused execution agent. Complete your mission using only the provided skills.

          Available skills: #{skills_text}

          Rules:
          - Call use_skill to execute skills. Only skills listed above are available.
          - Call request_help if you are blocked and need additional context or skills from the orchestrator.
          - Be concise in your final response — the orchestrator synthesizes for the user.
          - If a skill fails, report the error clearly. Do not retry indefinitely.
          - If you cannot complete the mission, explain what blocked you.\
          #{dep_section}#{context_section}\
          """
      end

    # Inject skill definitions for cache positioning (static section)
    prompt_with_skills =
      if skill_definitions_section != "" do
        base_prompt <> "\n\n" <> skill_definitions_section
      else
        base_prompt
      end

    # Inject context documents at the TOP of the prompt for cache positioning
    context_files = dispatch_params[:context_files] || []

    case load_context_files(context_files, dispatch_params) do
      {:ok, ""} ->
        {:ok, prompt_with_skills}

      {:ok, docs_section} ->
        {:ok, docs_section <> "\n\n" <> prompt_with_skills}

      {:error, _} = error ->
        error
    end
  end

  defp build_skill_definitions_section(skill_names) do
    definitions =
      skill_names
      |> Enum.sort()
      |> Enum.map(fn name ->
        case Registry.lookup(name) do
          {:ok, skill_def} ->
            body_preview = String.slice(skill_def.body, 0, 2000)

            """
            ### #{skill_def.name}
            #{skill_def.description}

            #{body_preview}\
            """

          {:error, :not_found} ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    case definitions do
      [] -> ""
      defs -> "## Available Skills\n\n" <> Enum.join(defs, "\n\n---\n\n")
    end
  end

  defp build_dependency_section(dep_results) when dep_results == %{}, do: ""

  defp build_dependency_section(dep_results) do
    results_text =
      Enum.map_join(dep_results, "\n\n", fn {dep_id, result} ->
        result_text = result[:result] || inspect(result)
        "Results from #{dep_id}:\n#{result_text}"
      end)

    "\n\nPrior agent results:\n#{results_text}"
  end

  defp build_context_section(nil), do: ""
  defp build_context_section(""), do: ""
  defp build_context_section(ctx), do: "\n\nAdditional context: #{ctx}"

  # --- Context File Loading ---

  # Reads context files and checks the total against the model's token budget.
  defp load_context_files([], _dispatch_params), do: {:ok, ""}

  defp load_context_files(file_paths, dispatch_params) do
    budget_tokens = compute_context_file_budget(dispatch_params)

    # Phase 1: Read all readable files, skip missing ones with a warning
    loaded_files =
      file_paths
      |> Enum.reduce([], fn path, acc ->
        case resolve_path(path) do
          {:ok, resolved} ->
            case File.read(resolved) do
              {:ok, contents} ->
                estimated_tokens = div(byte_size(contents), 4)
                [%{path: path, contents: contents, estimated_tokens: estimated_tokens} | acc]

              {:error, reason} ->
                Logger.warning("Context file not found or unreadable — skipping",
                  path: path,
                  resolved: resolved,
                  reason: inspect(reason),
                  agent_id: dispatch_params[:agent_id]
                )

                acc
            end

          {:error, :path_traversal_denied} ->
            Logger.warning("Context file path rejected — outside allowed base directory",
              path: path,
              agent_id: dispatch_params[:agent_id]
            )

            acc
        end
      end)
      |> Enum.reverse()

    # Phase 2: Check total against budget
    total_tokens = Enum.reduce(loaded_files, 0, fn f, sum -> sum + f.estimated_tokens end)

    if total_tokens > budget_tokens do
      file_breakdown =
        loaded_files
        |> Enum.map(fn f -> %{path: f.path, estimated_tokens: f.estimated_tokens} end)
        |> Enum.sort_by(& &1.estimated_tokens, :desc)

      {:error,
       {:context_budget_exceeded,
        %{
          estimated_tokens: total_tokens,
          budget_tokens: budget_tokens,
          overage_tokens: total_tokens - budget_tokens,
          files: file_breakdown
        }}}
    else
      case loaded_files do
        [] ->
          {:ok, ""}

        entries ->
          docs =
            Enum.map_join(entries, "\n---\n", fn %{path: path, contents: contents} ->
              "### #{path}\n#{contents}"
            end)

          {:ok, "## Context Documents\n#{docs}"}
      end
    end
  end

  defp compute_context_file_budget(dispatch_params) do
    model_info =
      case dispatch_params[:model_override] do
        nil ->
          Loader.model_for(:sub_agent)

        model_id ->
          Loader.model_for(:sub_agent, id: model_id)
      end

    max_context = (model_info && model_info.max_context_tokens) || 200_000
    limits = Loader.limits_config()

    target = limits.context_utilization_target
    reserve = limits.response_reserve_tokens

    available = trunc(max_context * target) - reserve
    div(max(available, 0), 2)
  end

  defp resolve_path(path) do
    base = File.cwd!()

    resolved =
      if Path.type(path) == :absolute do
        Path.expand(path)
      else
        Path.expand(path, base)
      end

    if String.starts_with?(resolved, base <> "/") or resolved == base do
      {:ok, resolved}
    else
      {:error, :path_traversal_denied}
    end
  end

  # --- Tool Definitions ---

  defp build_scoped_tools(skill_names) do
    allowed_skill_names =
      skill_names
      |> Enum.filter(&SkillPermissions.enabled?/1)
      |> Enum.uniq()

    # Look up each skill definition to build the scoped use_skill tool
    skill_defs =
      allowed_skill_names
      |> Enum.sort()
      |> Enum.map(fn name ->
        case Registry.lookup(name) do
          {:ok, skill_def} ->
            %{name: skill_def.name, description: skill_def.description}

          {:error, :not_found} ->
            %{name: name, description: "(skill not found in registry)"}
        end
      end)

    skills_desc =
      Enum.map_join(skill_defs, "\n", fn sd ->
        "  - #{sd.name}: #{sd.description}"
      end)

    use_skill_tool = %{
      type: "function",
      function: %{
        name: "use_skill",
        description: """
        Execute a skill. Available skills for this agent:\n#{skills_desc}\n\n\
        Call with the skill name and arguments as a JSON object.\
        """,
        parameters: %{
          "type" => "object",
          "properties" => %{
            "skill" => %{
              "type" => "string",
              "enum" => Enum.map(skill_defs, & &1.name),
              "description" => "The skill to execute"
            },
            "arguments" => %{
              "type" => "object",
              "description" => "Arguments for the skill as key-value pairs"
            }
          },
          "required" => ["skill", "arguments"]
        }
      }
    }

    request_help_tool = %{
      type: "function",
      function: %{
        name: "request_help",
        description: """
        Pause this task and request additional context, skills, or instructions \
        from the orchestrator. Use this when you are blocked and cannot complete \
        your mission with the current information or tools.

        The orchestrator may respond with new skills, updated instructions, \
        or additional context. Your conversation will resume after the response.\
        """,
        parameters: %{
          "type" => "object",
          "properties" => %{
            "reason" => %{
              "type" => "string",
              "description" =>
                "Describe what you need from the orchestrator — what information, " <>
                  "skills, or context would help you complete your mission."
            },
            "partial_results" => %{
              "type" => "string",
              "description" =>
                "Optional: describe what you've accomplished so far before getting stuck."
            }
          },
          "required" => ["reason"]
        }
      }
    }

    [use_skill_tool, request_help_tool]
  end

  defp record_llm_analytics(engine_state, response, model, status, reason \\ nil) do
    usage = if is_map(response), do: response[:usage] || %{}, else: %{}

    metadata =
      %{
        reason: if(reason, do: inspect(reason), else: nil)
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    Analytics.record_llm_call(%{
      status: status,
      scope: "sub_agent",
      model: if(is_map(response), do: response[:model] || model, else: model),
      conversation_id: engine_state[:conversation_id],
      user_id: engine_state[:user_id],
      prompt_tokens: usage[:prompt_tokens] || 0,
      completion_tokens: usage[:completion_tokens] || 0,
      total_tokens: usage[:total_tokens] || 0,
      cost: usage[:cost] || 0.0,
      metadata: metadata
    })
  end

  # --- Resume Helpers ---

  defp build_resume_content(update, _dispatch_params) do
    parts = []

    parts =
      if update[:message] do
        ["Orchestrator response: #{update.message}" | parts]
      else
        parts
      end

    parts =
      if update[:skills] do
        ["New skills added: #{Enum.join(update.skills, ", ")}" | parts]
      else
        parts
      end

    parts =
      if update[:context_files] do
        ["New context files provided: #{Enum.join(update.context_files, ", ")}" | parts]
      else
        parts
      end

    case parts do
      [] -> "Orchestrator acknowledged your request. Continue with your mission."
      _ -> Enum.reverse(parts) |> Enum.join("\n\n")
    end
  end

  defp build_skill_injection_messages(update) do
    case update[:skills] do
      nil ->
        []

      [] ->
        []

      new_skills ->
        definitions =
          new_skills
          |> Enum.map(fn name ->
            case Registry.lookup(name) do
              {:ok, skill_def} ->
                body_preview = String.slice(skill_def.body, 0, 2000)
                "### #{skill_def.name}\n#{skill_def.description}\n\n#{body_preview}"

              {:error, :not_found} ->
                nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        case definitions do
          [] ->
            []

          defs ->
            content =
              "Orchestrator update — new skills added:\n\n" <>
                Enum.join(defs, "\n\n---\n\n")

            [%{role: "user", content: content}]
        end
    end
  end

  defp maybe_add_skills(dispatch_params, nil), do: dispatch_params
  defp maybe_add_skills(dispatch_params, []), do: dispatch_params

  defp maybe_add_skills(dispatch_params, new_skills) do
    updated_skills = Enum.uniq(dispatch_params.skills ++ new_skills)
    %{dispatch_params | skills: updated_skills}
  end

  defp update_context_with_new_tools(context, new_messages, updated_dispatch) do
    new_tools = build_scoped_tools(updated_dispatch.skills)

    %{
      context
      | messages: new_messages,
        tools: new_tools,
        allowed_skills: updated_dispatch.skills
    }
  end

  # --- Synchronous wait helper ---

  defp wait_for_completion(_agent_id, monitor_ref) do
    receive do
      {:DOWN, ^monitor_ref, :process, _pid,
       {:shutdown, {:error, {:context_budget_exceeded, _}} = error}} ->
        # Context budget exceeded — return the error directly
        error

      {:DOWN, ^monitor_ref, :process, _pid, {:shutdown, %{status: _} = result_map}} ->
        # Normal completion — the GenServer packed its final result into the
        # shutdown reason so we can read it here (the process is already dead).
        result_map

      {:DOWN, ^monitor_ref, :process, _pid, :normal} ->
        # Should not happen after the {:shutdown, result} change, but handle
        # gracefully for safety.
        %{
          status: :completed,
          result: "Agent completed (status unavailable after shutdown).",
          tool_calls_used: 0,
          duration_ms: 0
        }

      {:DOWN, ^monitor_ref, :process, _pid, reason} ->
        %{
          status: :failed,
          result: "Sub-agent process exited: #{inspect(reason)}",
          tool_calls_used: 0,
          duration_ms: 0
        }
    after
      120_000 ->
        %{
          status: :timeout,
          result: "Sub-agent timed out after 120 seconds",
          tool_calls_used: 0,
          duration_ms: 120_000
        }
    end
  end

  defp build_final_result_map(state) do
    %{
      status: state.status,
      result: extract_result_text(state.result),
      tool_calls_used: state.tool_calls_used,
      duration_ms: state.duration_ms
    }
  end

  defp extract_result_text({:error, {:context_budget_exceeded, details}}) do
    "Context budget exceeded: #{inspect(details)}"
  end

  defp extract_result_text(text) when is_binary(text), do: text
  defp extract_result_text(nil), do: nil
  defp extract_result_text(other), do: inspect(other)

  defp elapsed_ms(started_at) do
    System.monotonic_time(:millisecond) - started_at
  end

  defp build_skill_context(dispatch_params, engine_state) do
    root_conversation_id =
      engine_state[:parent_conversation_id] || engine_state[:conversation_id] || "unknown"

    %Context{
      conversation_id: engine_state[:conversation_id] || "unknown",
      execution_id: Ecto.UUID.generate(),
      user_id: engine_state[:user_id] || "unknown",
      channel: engine_state[:channel],
      integrations: Assistant.Integrations.Registry.default_integrations(),
      metadata: %{
        agent_id: dispatch_params.agent_id,
        root_conversation_id: root_conversation_id,
        agent_type: engine_state[:agent_type] || :orchestrator
      }
    }
  end

  defp build_model_opts(dispatch_params, context) do
    model =
      case dispatch_params[:model_override] do
        nil -> LLMHelpers.resolve_model(:sub_agent)
        override -> override
      end

    LLMHelpers.build_llm_opts(context.tools, model)
  end

  # --- Registry ---

  defp via_tuple(agent_id) do
    {:via, Elixir.Registry, {Assistant.SubAgent.Registry, agent_id}}
  end

  # --- Response Parsing Helpers (delegated to LLMHelpers) ---

  defp has_text_no_tools?(response), do: LLMHelpers.text_response?(response)
  defp has_tool_calls?(response), do: LLMHelpers.tool_call_response?(response)
  defp extract_function_name(tc), do: LLMHelpers.extract_function_name(tc)
  defp extract_function_args(tc), do: LLMHelpers.extract_function_args(tc)
  defp extract_last_text(messages), do: LLMHelpers.extract_last_assistant_text(messages)
end
