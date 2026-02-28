# lib/assistant/orchestrator/sub_agent/context_builder.ex — Context assembly
# for sub-agent LLM loops.
#
# Builds the initial context map (system prompt, messages, tools) from
# dispatch params and dependency results. Handles context file loading
# with token budget enforcement.
#
# Related files:
#   - lib/assistant/orchestrator/sub_agent.ex (calls build/3 from handle_continue)
#   - lib/assistant/orchestrator/sub_agent/tool_defs.ex (tool schemas)
#   - lib/assistant/config/prompt_loader.ex (sub-agent system prompt template)
#   - lib/assistant/config/loader.ex (model + limits config)

defmodule Assistant.Orchestrator.SubAgent.ContextBuilder do
  @moduledoc false

  alias Assistant.Config.{Loader, PromptLoader}
  alias Assistant.Orchestrator.SubAgent.ToolDefs
  alias Assistant.Skills.Registry

  require Logger

  @doc """
  Builds the initial context for a sub-agent's LLM loop.

  Returns `{:ok, context}` or `{:error, {:context_budget_exceeded, details}}`.
  """
  @spec build(map(), map(), map()) ::
          {:ok, map()} | {:error, {:context_budget_exceeded, map()}}
  def build(dispatch_params, dep_results, _engine_state) do
    case build_system_prompt(dispatch_params, dep_results) do
      {:error, _} = error ->
        error

      {:ok, system_prompt} ->
        tools = ToolDefs.build_scoped_tools(dispatch_params.skills)
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

  # --- System Prompt ---

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

  # --- Prompt Sections ---

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

  defp load_context_files([], _dispatch_params), do: {:ok, ""}

  defp load_context_files(file_paths, dispatch_params) do
    budget_tokens = compute_context_file_budget(dispatch_params)

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
end
