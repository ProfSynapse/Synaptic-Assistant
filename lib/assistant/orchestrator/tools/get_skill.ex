# lib/assistant/orchestrator/tools/get_skill.ex — Progressive-disclosure skill discovery tool.
#
# Meta-tool that the orchestrator LLM calls to discover available skills.
# Implements four levels of progressive disclosure:
#   get_skill()              -> list all domain summaries
#   get_skill("email")       -> return SKILL.md index for the domain
#   get_skill("email.send")  -> return specific skill definition
#   get_skill("email.all")   -> return all skills in the domain
#
# Reads from Assistant.Skills.Registry (ETS). Never modifies state.

defmodule Assistant.Orchestrator.Tools.GetSkill do
  @moduledoc """
  Progressive-disclosure skill discovery for the orchestrator LLM.

  The orchestrator calls this tool to understand what capabilities exist
  before planning sub-agent missions. Returns CLI-style help text, not
  JSON schemas, to stay consistent with the CLI-first interface.

  ## Disclosure Levels

    * No arguments — domain summary list
    * `domain` only (e.g., "email") — SKILL.md index for that domain
    * Specific skill (e.g., "email.send") — full skill definition body
    * Domain + ".all" (e.g., "email.all") — all skills in the domain
    * `search` keyword — full-text search across names, descriptions, tags
  """

  alias Assistant.Skills.{DomainIndex, Registry, SkillDefinition}

  require Logger

  @doc """
  Returns the OpenAI-compatible function tool definition for get_skill.

  The `domain` enum is populated dynamically from the skill registry
  at call time (not compile time) so it reflects hot-reloaded skills.
  """
  @spec tool_definition() :: map()
  def tool_definition do
    domains = list_available_domains()

    %{
      name: "get_skill",
      description: """
      Discover available skills (capabilities). Call this to find out what \
      you can do in a specific domain or to search for a skill by keyword.

      Progressive disclosure:
      - No arguments: list all domains with descriptions
      - skill_or_domain = "email": SKILL.md index for the email domain
      - skill_or_domain = "email.send": full definition for a specific skill
      - skill_or_domain = "email.all": all skill definitions in the domain
      - search = "send": search skills by keyword in name/description/tags

      You MUST call get_skill before dispatch_agent if you don't already \
      know the exact skill names and their capabilities.\
      """,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "skill_or_domain" => %{
            "type" => "string",
            "description" =>
              "A domain name (e.g., \"email\"), a specific skill (e.g., " <>
                "\"email.send\"), or a domain + \".all\" (e.g., \"email.all\")." <>
                " Available domains: #{Enum.join(domains, ", ")}"
          },
          "search" => %{
            "type" => "string",
            "description" =>
              "Search for skills by keyword in name, description, or tags. " <>
                "Returns matching skills across all domains."
          }
        },
        "required" => []
      }
    }
  end

  @doc """
  Executes the get_skill discovery request.

  Returns `{:ok, %Result{}}` with help text content appropriate
  to the disclosure level requested.
  """
  @spec execute(map(), term()) :: {:ok, Assistant.Skills.Result.t()}
  def execute(params, _context) do
    result = resolve(params)

    Logger.debug("get_skill executed",
      params: inspect(params),
      content_length: String.length(result.content)
    )

    {:ok, result}
  end

  # --- Resolution logic ---

  defp resolve(%{"search" => query}) when is_binary(query) and query != "" do
    results = Registry.search(query)
    format_search_results(query, results)
  end

  defp resolve(%{"skill_or_domain" => value}) when is_binary(value) and value != "" do
    cond do
      String.ends_with?(value, ".all") ->
        domain = String.trim_trailing(value, ".all")
        resolve_domain_all(domain)

      String.contains?(value, ".") ->
        resolve_specific_skill(value)

      true ->
        resolve_domain(value)
    end
  end

  defp resolve(_params) do
    resolve_all_domains()
  end

  # Level 0: List all domains with summaries
  defp resolve_all_domains do
    indexes = Registry.list_domain_indexes()

    if indexes == [] do
      %Assistant.Skills.Result{
        status: :ok,
        content: "No skill domains are currently registered.",
        metadata: %{level: :domains, domain_count: 0}
      }
    else
      lines =
        Enum.map_join(indexes, "\n", fn %DomainIndex{} = idx ->
          skill_count = length(Registry.list_by_domain(idx.domain))
          "  #{idx.domain} (#{skill_count} skills): #{idx.description}"
        end)

      total = Enum.sum(for idx <- indexes, do: length(Registry.list_by_domain(idx.domain)))

      %Assistant.Skills.Result{
        status: :ok,
        content: """
        Available domains (#{length(indexes)} domains, #{total} skills total):

        #{lines}

        Call get_skill with a specific domain to see its SKILL.md index, \
        or use "domain.all" to see all skills in a domain.\
        """,
        metadata: %{level: :domains, domain_count: length(indexes)}
      }
    end
  end

  # Level 1: Show SKILL.md index for a domain
  defp resolve_domain(domain) do
    case Registry.get_domain_index(domain) do
      {:ok, %DomainIndex{} = index} ->
        %Assistant.Skills.Result{
          status: :ok,
          content: index.body,
          metadata: %{level: :domain_index, domain: domain}
        }

      {:error, :not_found} ->
        available = list_available_domains()

        %Assistant.Skills.Result{
          status: :error,
          content:
            "Unknown domain \"#{domain}\". " <>
              "Available domains: #{Enum.join(available, ", ")}",
          metadata: %{level: :domain_index, domain: domain}
        }
    end
  end

  # Level 2: Show a specific skill's full definition
  defp resolve_specific_skill(skill_name) do
    case Registry.lookup(skill_name) do
      {:ok, %SkillDefinition{} = skill} ->
        %Assistant.Skills.Result{
          status: :ok,
          content: skill.body,
          metadata: %{level: :skill, skill: skill_name, domain: skill.domain}
        }

      {:error, :not_found} ->
        # Try to suggest the domain
        [domain | _] = String.split(skill_name, ".", parts: 2)
        domain_skills = Registry.list_by_domain(domain)

        suggestion =
          if domain_skills != [] do
            names = Enum.map_join(domain_skills, ", ", & &1.name)
            " Available skills in #{domain}: #{names}"
          else
            available = list_available_domains()
            " Available domains: #{Enum.join(available, ", ")}"
          end

        %Assistant.Skills.Result{
          status: :error,
          content: "Unknown skill \"#{skill_name}\".#{suggestion}",
          metadata: %{level: :skill, skill: skill_name}
        }
    end
  end

  # Level 3: Show all skills in a domain
  defp resolve_domain_all(domain) do
    skills = Registry.list_by_domain(domain)

    if skills == [] do
      available = list_available_domains()

      %Assistant.Skills.Result{
        status: :error,
        content:
          "No skills found in domain \"#{domain}\". " <>
            "Available domains: #{Enum.join(available, ", ")}",
        metadata: %{level: :domain_all, domain: domain}
      }
    else
      sections =
        Enum.map_join(skills, "\n\n---\n\n", fn %SkillDefinition{} = skill ->
          "## #{skill.name}\n\n#{skill.body}"
        end)

      %Assistant.Skills.Result{
        status: :ok,
        content: "All #{length(skills)} skills in \"#{domain}\":\n\n#{sections}",
        metadata: %{level: :domain_all, domain: domain, skill_count: length(skills)}
      }
    end
  end

  # Search: keyword match across names, descriptions, tags
  defp format_search_results(query, []) do
    %Assistant.Skills.Result{
      status: :ok,
      content: "No skills found matching \"#{query}\".",
      metadata: %{level: :search, query: query, result_count: 0}
    }
  end

  defp format_search_results(query, results) do
    lines =
      Enum.map_join(results, "\n", fn %SkillDefinition{} = skill ->
        tags = if skill.tags != [], do: " [#{Enum.join(skill.tags, ", ")}]", else: ""
        "  #{skill.name}: #{skill.description}#{tags}"
      end)

    %Assistant.Skills.Result{
      status: :ok,
      content: """
      Found #{length(results)} skills matching "#{query}":

      #{lines}

      Call get_skill with a specific skill name for full details.\
      """,
      metadata: %{level: :search, query: query, result_count: length(results)}
    }
  end

  # --- Helpers ---

  defp list_available_domains do
    Registry.list_domain_indexes()
    |> Enum.map(& &1.domain)
    |> Enum.sort()
  end
end
