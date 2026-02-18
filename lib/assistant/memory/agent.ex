# lib/assistant/memory/agent.ex — Persistent GenServer for memory operations.
#
# One MemoryAgent per user session. Wraps the same LLM loop pattern as
# SubAgent but with memory-specific behavior: dynamic skill loading from
# priv/skills/memory/, search-first enforcement via SkillExecutor, and
# persistent process lifetime (not one-shot like sub-agents).
#
# Can be dispatched to by: ContextMonitor (background triggers),
# TurnClassifier (conversation-driven), or orchestrator (manual).
#
# Related files:
#   - lib/assistant/orchestrator/sub_agent.ex (LLM loop pattern origin)
#   - lib/assistant/memory/skill_executor.ex (search-first enforcement)
#   - lib/assistant/skills/registry.ex (skill loading)
#   - config/prompts/memory_agent.yaml (system prompt template)
#   - priv/skills/memory/ (skill definitions)

defmodule Assistant.Memory.Agent do
  @moduledoc """
  Persistent GenServer that handles all memory operations for a user session.

  The MemoryAgent manages saving/searching memories, maintaining the entity
  knowledge graph, and compacting conversations into long-term storage.
  It enforces the search-first rule via `Memory.SkillExecutor`.

  ## Lifecycle

  Unlike sub-agents (which are ephemeral per-mission), the MemoryAgent
  persists for the duration of a user session. It can handle multiple
  dispatch missions sequentially.

  1. `start_link/1` — starts the GenServer, registers via `{:memory_agent, user_id}`
  2. `dispatch/2` — send a mission; the agent runs its LLM loop
  3. On mission complete → returns to `:idle` state, awaiting next dispatch
  4. On error → logs and returns to `:idle`

  ## States

    * `:idle` — ready to accept a new dispatch mission
    * `:running` — LLM loop is actively processing a mission
    * `:awaiting_orchestrator` — paused, waiting for orchestrator help

  ## Skill Loading

  Memory skills are loaded dynamically from `priv/skills/memory/` via
  `Skills.Registry` at init time. Skill definitions are injected into
  the system prompt so the LLM knows what tools are available.

  ## Configuration

  The LLM client is injected via `Application.compile_env/3` for testability.
  """

  use GenServer

  alias Assistant.Config.PromptLoader
  alias Assistant.Memory.SkillExecutor
  alias Assistant.Orchestrator.{Limits, Sentinel}
  alias Assistant.Skills.{Context, Registry, Result}

  require Logger

  @llm_client Application.compile_env(
                :assistant,
                :llm_client,
                Assistant.Integrations.OpenRouter
              )

  @memory_domain "memory"
  @default_max_tool_calls 15
  @default_timeout_ms 30_000

  # --- Client API ---

  @doc """
  Start the MemoryAgent GenServer for a user.

  ## Parameters

    * `opts` - Keyword list with:
      * `:user_id` - (required) The user this agent serves

  ## Returns

    * `{:ok, pid}` on success
    * `{:error, reason}` on failure
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    user_id = Keyword.fetch!(opts, :user_id)

    GenServer.start_link(__MODULE__, opts,
      name: via_tuple(user_id)
    )
  end

  @doc """
  Dispatch a mission to the memory agent.

  The agent must be in `:idle` state. The mission describes what the
  agent should do (e.g., "Compact the last 50 messages" or "Extract
  entities from this text: ...").

  ## Parameters

    * `user_id` - The user whose memory agent to dispatch to
    * `params` - Map with:
      * `:mission` - (required) Natural language mission description
      * `:conversation_id` - (optional) Associated conversation UUID
      * `:max_tool_calls` - (optional) Override tool budget
      * `:original_request` - (optional) The user's original request for Sentinel

  ## Returns

    * `:ok` if dispatch was accepted
    * `{:error, :busy}` if agent is already running a mission
    * `{:error, :not_found}` if no agent registered for this user
  """
  @spec dispatch(String.t(), map()) :: :ok | {:error, :busy | :not_found}
  def dispatch(user_id, params) do
    GenServer.call(via_tuple(user_id), {:dispatch, params})
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
  end

  @doc """
  Get the current status of the memory agent.

  ## Returns

    * `{:ok, status_map}` with keys: `:status`, `:last_result`, `:missions_completed`
    * `{:error, :not_found}` if no agent registered for this user
  """
  @spec get_status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_status(user_id) do
    GenServer.call(via_tuple(user_id), :get_status)
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
  end

  @doc """
  Resume a paused memory agent with orchestrator context.

  The agent must be in `:awaiting_orchestrator` state.

  ## Parameters

    * `user_id` - The user whose memory agent to resume
    * `update` - Map with orchestrator response (`:message`, optional `:skills`)

  ## Returns

    * `:ok` if agent was paused and is now resuming
    * `{:error, :not_awaiting}` if agent is not in awaiting state
    * `{:error, :not_found}` if no agent registered for this user
  """
  @spec resume(String.t(), map()) :: :ok | {:error, :not_awaiting | :not_found}
  def resume(user_id, update) do
    GenServer.call(via_tuple(user_id), {:resume, update})
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    user_id = Keyword.fetch!(opts, :user_id)

    # Load memory skills from registry
    memory_skills = load_memory_skills()
    skill_names = Enum.map(memory_skills, & &1.name)

    Logger.info("MemoryAgent starting",
      user_id: user_id,
      skills_loaded: length(skill_names)
    )

    state = %{
      user_id: user_id,
      status: :idle,
      memory_skills: skill_names,
      skill_definitions: memory_skills,
      last_result: nil,
      missions_completed: 0,
      # Active mission state (populated on dispatch)
      current_mission: nil,
      loop_task: nil,
      loop_ref: nil,
      started_at: nil,
      # Pause/resume state
      awaiting_reason: nil,
      pending_help_tc: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:dispatch, params}, _from, %{status: :idle} = state) do
    mission = Map.fetch!(params, :mission)
    conversation_id = params[:conversation_id] || Ecto.UUID.generate()
    max_calls = params[:max_tool_calls] || @default_max_tool_calls

    Logger.info("MemoryAgent dispatched",
      user_id: state.user_id,
      mission_preview: String.slice(mission, 0, 100),
      conversation_id: conversation_id
    )

    new_state = %{
      state
      | status: :running,
        current_mission: params,
        started_at: System.monotonic_time(:millisecond)
    }

    # Build context and start loop asynchronously
    {:reply, :ok, new_state, {:continue, {:start_mission, conversation_id, max_calls}}}
  end

  @impl true
  def handle_call({:dispatch, _params}, _from, state) do
    {:reply, {:error, :busy}, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status_map = %{
      status: state.status,
      last_result: state.last_result,
      missions_completed: state.missions_completed,
      skills: state.memory_skills
    }

    {:reply, {:ok, status_map}, state}
  end

  @impl true
  def handle_call({:resume, update}, _from, %{status: :awaiting_orchestrator} = state) do
    Logger.info("MemoryAgent resuming after orchestrator update",
      user_id: state.user_id,
      has_message: update[:message] != nil
    )

    send(state.loop_task.pid, {:resume, update})

    {:reply, :ok, %{state | status: :running, awaiting_reason: nil}}
  end

  @impl true
  def handle_call({:resume, _update}, _from, state) do
    {:reply, {:error, :not_awaiting}, state}
  end

  # --- Continue: Start Mission ---

  @impl true
  def handle_continue({:start_mission, conversation_id, max_calls}, state) do
    context = build_context(state, conversation_id)
    agent_limit_state = Limits.new_agent_state(max_skill_calls: max_calls)
    executor_session = SkillExecutor.new_session()

    parent = self()

    task =
      Task.async(fn ->
        run_loop(context, agent_limit_state, executor_session, state, parent)
      end)

    {:noreply, %{state | loop_task: task, loop_ref: task.ref}}
  end

  # --- Info handlers ---

  @impl true
  def handle_info({:loop_paused, reason, help_tc}, state) do
    Logger.info("MemoryAgent paused — awaiting orchestrator",
      user_id: state.user_id,
      reason: reason
    )

    {:noreply,
     %{
       state
       | status: :awaiting_orchestrator,
         awaiting_reason: reason,
         pending_help_tc: help_tc
     }}
  end

  @impl true
  def handle_info({ref, result}, %{loop_ref: ref} = state) do
    # Task completed normally
    Process.demonitor(ref, [:flush])

    duration_ms = elapsed_ms(state.started_at)
    result_text = extract_result_text(result)

    Logger.info("MemoryAgent mission completed",
      user_id: state.user_id,
      duration_ms: duration_ms,
      result_preview: String.slice(result_text || "", 0, 100)
    )

    {:noreply,
     %{
       state
       | status: :idle,
         last_result: result_text,
         missions_completed: state.missions_completed + 1,
         current_mission: nil,
         loop_task: nil,
         loop_ref: nil,
         started_at: nil,
         awaiting_reason: nil,
         pending_help_tc: nil
     }}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{loop_ref: ref} = state) do
    # Task crashed
    Logger.error("MemoryAgent loop task crashed",
      user_id: state.user_id,
      reason: inspect(reason)
    )

    {:noreply,
     %{
       state
       | status: :idle,
         last_result: "Mission failed: #{inspect(reason)}",
         current_mission: nil,
         loop_task: nil,
         loop_ref: nil,
         started_at: nil,
         awaiting_reason: nil,
         pending_help_tc: nil
     }}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- LLM Loop (runs in Task) ---

  defp run_loop(context, agent_state, executor_session, gen_state, parent) do
    model_opts = build_model_opts(context)

    case @llm_client.chat_completion(context.messages, model_opts) do
      {:ok, response} ->
        handle_response(response, context, agent_state, executor_session, gen_state, parent)

      {:error, reason} ->
        Logger.error("MemoryAgent LLM call failed",
          user_id: gen_state.user_id,
          reason: inspect(reason)
        )

        %{
          status: :failed,
          result: "LLM call failed: #{inspect(reason)}",
          tool_calls_used: agent_state.skill_calls
        }
    end
  end

  defp handle_response(response, context, agent_state, executor_session, gen_state, parent) do
    cond do
      has_text_no_tools?(response) ->
        %{
          status: :completed,
          result: response.content,
          tool_calls_used: agent_state.skill_calls
        }

      has_tool_calls?(response) ->
        execute_tool_calls(
          response.tool_calls,
          response,
          context,
          agent_state,
          executor_session,
          gen_state,
          parent
        )

      true ->
        %{
          status: :completed,
          result: response[:content] || "Memory agent completed with no output.",
          tool_calls_used: agent_state.skill_calls
        }
    end
  end

  defp execute_tool_calls(tool_calls, _response, context, agent_state, executor_session, gen_state, parent) do
    call_count = length(tool_calls)

    case Limits.check_agent(agent_state, call_count) do
      {:ok, new_agent_state} ->
        # Separate help calls from skill calls
        {help_calls, skill_calls} =
          Enum.split_with(tool_calls, fn tc ->
            extract_function_name(tc) == "request_help"
          end)

        # Execute skill calls with search-first enforcement
        {results, final_agent_state, final_session} =
          Enum.reduce(skill_calls, {[], new_agent_state, executor_session}, fn tc, {acc_results, acc_agent, acc_session} ->
            {result, updated_session} =
              execute_single_tool(tc, gen_state, acc_session)

            {[result | acc_results], acc_agent, updated_session}
          end)

        results = Enum.reverse(results)

        # Build messages
        assistant_msg = %{role: "assistant", tool_calls: tool_calls}

        tool_msgs =
          Enum.map(results, fn {tc, result_content} ->
            %{role: "tool", tool_call_id: tc.id, content: result_content}
          end)

        new_messages = context.messages ++ [assistant_msg | tool_msgs]

        # Handle request_help
        case help_calls do
          [help_tc | _] ->
            help_args = extract_function_args(help_tc)
            reason = help_args["reason"] || "Memory agent requests assistance"

            send(parent, {:loop_paused, reason, help_tc})

            receive do
              {:resume, update} ->
                resume_content = build_resume_content(update)

                help_result_msg = %{
                  role: "tool",
                  tool_call_id: help_tc.id,
                  content: resume_content
                }

                resumed_messages = new_messages ++ [help_result_msg]
                new_context = %{context | messages: resumed_messages}

                run_loop(new_context, final_agent_state, final_session, gen_state, parent)
            end

          [] ->
            new_context = %{context | messages: new_messages}
            run_loop(new_context, final_agent_state, final_session, gen_state, parent)
        end

      {:error, :limit_exceeded, _details} ->
        Logger.info("MemoryAgent tool budget exhausted",
          user_id: gen_state.user_id,
          used: agent_state.skill_calls,
          max: agent_state.max_skill_calls
        )

        last_text = extract_last_assistant_text(context.messages)

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

  defp execute_single_tool(tc, gen_state, executor_session) do
    name = extract_function_name(tc)
    args = extract_function_args(tc)

    case name do
      "use_skill" ->
        execute_use_skill(tc, args, gen_state, executor_session)

      "request_help" ->
        # Handled upstream; this is a fallback
        {{tc, "Request acknowledged. Waiting for orchestrator response."}, executor_session}

      other ->
        {{tc, "Error: Unknown tool \"#{other}\". Only use_skill and request_help are available."}, executor_session}
    end
  end

  defp execute_use_skill(tc, args, gen_state, executor_session) do
    skill_name = args["skill"]
    skill_args = args["arguments"] || %{}

    if skill_name in gen_state.memory_skills do
      # Sentinel security gate
      proposed_action = %{
        skill_name: skill_name,
        arguments: skill_args,
        agent_id: "memory_agent:#{gen_state.user_id}"
      }

      original_request = get_in(gen_state, [:current_mission, :original_request])

      # Phase 1: Sentinel stub always approves. Phase 2 will add rejection handling.
      {:ok, :approved} = Sentinel.check(original_request, "memory management", proposed_action)
      execute_with_search_first(tc, skill_name, skill_args, gen_state, executor_session)
    else
      {{tc,
        "Error: Skill \"#{skill_name}\" is not available. " <>
          "Available skills: #{Enum.join(gen_state.memory_skills, ", ")}"}, executor_session}
    end
  end

  defp execute_with_search_first(tc, skill_name, skill_args, gen_state, executor_session) do
    # Look up handler from skill definition
    handler =
      case Registry.lookup(skill_name) do
        {:ok, skill_def} -> skill_def.handler
        {:error, :not_found} -> nil
      end

    skill_context = build_skill_context(gen_state)

    case SkillExecutor.execute(skill_name, handler, skill_args, skill_context, executor_session,
           timeout: @default_timeout_ms
         ) do
      {:ok, %Result{} = result, updated_session} ->
        Limits.record_skill_success(skill_name)
        {{tc, result.content}, updated_session}

      {:error, :memory_write_without_search, updated_session} ->
        nudge = Assistant.Orchestrator.Nudger.lookup(:memory_write_without_search) || ""

        {{tc, "Error: Write rejected — you must search before writing.\n\n#{nudge}"},
         updated_session}

      {:error, reason, updated_session} ->
        Limits.record_skill_failure(skill_name)
        {{tc, "Skill execution failed: #{inspect(reason)}"}, updated_session}
    end
  end

  # --- Context Building ---

  defp build_context(state, conversation_id) do
    system_prompt = build_system_prompt(state)
    tools = build_scoped_tools(state.memory_skills)
    mission = state.current_mission.mission
    mission_msg = %{role: "user", content: mission}

    %{
      system_prompt: system_prompt,
      messages: [%{role: "system", content: system_prompt}, mission_msg],
      tools: tools,
      allowed_skills: state.memory_skills,
      conversation_id: conversation_id
    }
  end

  defp build_system_prompt(state) do
    skills_text = build_skills_text(state.skill_definitions)
    current_date = Date.utc_today() |> Date.to_iso8601()

    assigns = %{
      current_date: current_date,
      skills_text: skills_text
    }

    case PromptLoader.render(:memory_agent, assigns) do
      {:ok, rendered} ->
        rendered

      {:error, _reason} ->
        Logger.warning("PromptLoader fallback for :memory_agent — using hardcoded prompt")

        """
        You are the Memory Agent. You maintain persistent memory and a knowledge graph.

        Date: #{current_date}

        Available skills: #{Enum.join(state.memory_skills, ", ")}

        Rules:
        - Always search before writing. Write operations will fail if you haven't searched first.
        - Never delete — close old relations and open new ones.
        - Be factual and precise.
        - Use request_help if you encounter ambiguous conflicts.

        #{skills_text}\
        """
    end
  end

  defp build_skills_text(skill_definitions) do
    skill_definitions
    |> Enum.sort_by(& &1.name)
    |> Enum.map_join("\n\n---\n\n", fn skill_def ->
      body_preview = String.slice(skill_def.body, 0, 2000)

      """
      ### #{skill_def.name}
      #{skill_def.description}

      #{body_preview}\
      """
    end)
  end

  defp build_scoped_tools(skill_names) do
    skill_defs =
      skill_names
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
        Execute a memory skill. Available skills:\n#{skills_desc}\n\n\
        Call with the skill name and arguments as a JSON object.\
        """,
        parameters: %{
          "type" => "object",
          "properties" => %{
            "skill" => %{
              "type" => "string",
              "enum" => Enum.map(skill_defs, & &1.name),
              "description" => "The memory skill to execute"
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
        Pause and request help from the orchestrator. Use when you encounter \
        ambiguous conflicts between existing and new information, or when you \
        need additional context to make a decision about memory operations.\
        """,
        parameters: %{
          "type" => "object",
          "properties" => %{
            "reason" => %{
              "type" => "string",
              "description" => "Describe the conflict or what additional context you need."
            },
            "partial_results" => %{
              "type" => "string",
              "description" => "What you've accomplished so far before getting stuck."
            }
          },
          "required" => ["reason"]
        }
      }
    }

    [use_skill_tool, request_help_tool]
  end

  # --- Skill Loading ---

  defp load_memory_skills do
    Registry.list_by_domain(@memory_domain)
  end

  # --- Helper Functions ---

  defp build_skill_context(gen_state) do
    %Context{
      conversation_id: get_in(gen_state, [:current_mission, :conversation_id]) || "unknown",
      execution_id: Ecto.UUID.generate(),
      user_id: gen_state.user_id,
      metadata: %{
        agent_id: "memory_agent:#{gen_state.user_id}",
        agent_type: :memory_agent
      }
    }
  end

  defp build_model_opts(context) do
    [tools: context.tools]
  end

  defp build_resume_content(update) do
    parts = []

    parts =
      if update[:message] do
        ["Orchestrator response: #{update.message}" | parts]
      else
        parts
      end

    case parts do
      [] -> "Orchestrator acknowledged your request. Continue with your mission."
      _ -> Enum.reverse(parts) |> Enum.join("\n\n")
    end
  end

  defp via_tuple(user_id) do
    {:via, Registry, {Assistant.Memory.AgentRegistry, user_id}}
  end

  defp elapsed_ms(nil), do: 0

  defp elapsed_ms(started_at) do
    System.monotonic_time(:millisecond) - started_at
  end

  defp extract_result_text(%{result: text}) when is_binary(text), do: text
  defp extract_result_text(text) when is_binary(text), do: text
  defp extract_result_text(nil), do: nil
  defp extract_result_text(other), do: inspect(other)

  defp extract_last_assistant_text(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{role: "assistant", content: content} when is_binary(content) and content != "" ->
        content

      _ ->
        nil
    end)
  end

  # --- Response Parsing ---

  defp has_text_no_tools?(response) do
    content = response[:content]
    tool_calls = response[:tool_calls]

    content != nil and content != "" and
      (tool_calls == nil or tool_calls == [])
  end

  defp has_tool_calls?(response) do
    is_list(response[:tool_calls]) and response[:tool_calls] != []
  end

  defp extract_function_name(%{function: %{name: name}}), do: name
  defp extract_function_name(%{"function" => %{"name" => name}}), do: name
  defp extract_function_name(_), do: "unknown"

  defp extract_function_args(%{function: %{arguments: args}}) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{}
    end
  end

  defp extract_function_args(%{function: %{arguments: args}}) when is_map(args), do: args

  defp extract_function_args(%{"function" => %{"arguments" => args}}) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{}
    end
  end

  defp extract_function_args(%{"function" => %{"arguments" => args}}) when is_map(args), do: args
  defp extract_function_args(_), do: %{}
end
