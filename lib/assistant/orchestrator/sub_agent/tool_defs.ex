# lib/assistant/orchestrator/sub_agent/tool_defs.ex — Tool definitions for sub-agents.
#
# Builds the JSON-schema tool definitions (use_skill, request_help) that
# are sent to the LLM for each sub-agent loop iteration. The use_skill
# tool's `enum` is scoped to only the skills the orchestrator granted.
#
# Related files:
#   - lib/assistant/orchestrator/sub_agent/context_builder.ex (uses build_scoped_tools/1)
#   - lib/assistant/orchestrator/sub_agent/loop.ex (uses for resume with new skills)
#   - lib/assistant/skills/registry.ex (skill definition lookup)

defmodule Assistant.Orchestrator.SubAgent.ToolDefs do
  @moduledoc false

  alias Assistant.SkillPermissions
  alias Assistant.Skills.Registry

  @doc """
  Builds the scoped tool definitions for a sub-agent.

  Returns a list of two tool definitions: `use_skill` (scoped to allowed
  skills) and `request_help`.
  """
  @spec build_scoped_tools([String.t()]) :: [map()]
  def build_scoped_tools(skill_names) do
    allowed_skill_names =
      skill_names
      |> Enum.filter(&SkillPermissions.enabled?/1)
      |> Enum.uniq()

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

    [use_skill_tool(skill_defs, skills_desc), request_help_tool()]
  end

  # --- Tool Schemas ---

  defp use_skill_tool(skill_defs, skills_desc) do
    %{
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
  end

  defp request_help_tool do
    %{
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
  end
end
