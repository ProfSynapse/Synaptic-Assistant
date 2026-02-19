# lib/assistant/skills/loader.ex — Load and validate skill markdown files.
#
# Reads .md files from the skills directory, parses YAML frontmatter,
# and produces SkillDefinition and DomainIndex structs. Used by the
# Registry at startup and on hot-reload events from the Watcher.

defmodule Assistant.Skills.Loader do
  @moduledoc """
  Loads skill markdown files from disk and parses them into
  `SkillDefinition` and `DomainIndex` structs.

  Handles YAML frontmatter extraction, domain derivation from
  directory path, handler module resolution, and validation.
  """

  alias Assistant.Skills.{DomainIndex, SkillDefinition}

  require Logger

  @doc """
  Load all skill files and domain indexes from the given directory.

  Returns `{skills, domain_indexes}` where skills is a list of
  valid `SkillDefinition` structs and domain_indexes is a list of
  valid `DomainIndex` structs.
  """
  @spec load_all(String.t()) :: {[SkillDefinition.t()], [DomainIndex.t()]}
  def load_all(dir) do
    all_files = Path.wildcard(Path.join(dir, "**/*.md"))

    {index_files, skill_files} =
      Enum.split_with(all_files, fn path ->
        Path.basename(path) == "SKILL.md"
      end)

    skills =
      skill_files
      |> Enum.map(fn path -> load_skill_file(path, dir) end)
      |> Enum.reject(&is_nil/1)

    domain_indexes =
      index_files
      |> Enum.map(fn path -> load_domain_index(path, dir) end)
      |> Enum.reject(&is_nil/1)

    {skills, domain_indexes}
  end

  @doc """
  Load a single skill file and return a SkillDefinition or nil on failure.
  """
  @spec load_skill_file(String.t(), String.t()) :: SkillDefinition.t() | nil
  def load_skill_file(path, skills_root) do
    case File.read(path) do
      {:ok, content} ->
        case parse_frontmatter(content) do
          {:ok, frontmatter, body} ->
            build_skill_definition(frontmatter, body, path, skills_root)

          {:error, reason} ->
            Logger.warning("Failed to parse skill file",
              path: path,
              reason: inspect(reason)
            )

            nil
        end

      {:error, reason} ->
        Logger.warning("Failed to read skill file",
          path: path,
          reason: inspect(reason)
        )

        nil
    end
  end

  @doc """
  Load a single SKILL.md domain index and return a DomainIndex or nil on failure.
  """
  @spec load_domain_index(String.t(), String.t()) :: DomainIndex.t() | nil
  def load_domain_index(path, skills_root) do
    case File.read(path) do
      {:ok, content} ->
        case parse_frontmatter(content) do
          {:ok, frontmatter, body} ->
            build_domain_index(frontmatter, body, path, skills_root)

          {:error, reason} ->
            Logger.warning("Failed to parse domain index",
              path: path,
              reason: inspect(reason)
            )

            nil
        end

      {:error, reason} ->
        Logger.warning("Failed to read domain index",
          path: path,
          reason: inspect(reason)
        )

        nil
    end
  end

  @doc """
  Parse YAML frontmatter delimited by `---` from markdown content.

  Returns `{:ok, frontmatter_map, body_string}` or `{:error, reason}`.
  """
  @spec parse_frontmatter(String.t()) :: {:ok, map(), String.t()} | {:error, term()}
  def parse_frontmatter(content) do
    case String.split(content, ~r/^---\s*$/m, parts: 3) do
      [_before, yaml_string, body] ->
        case YamlElixir.read_from_string(yaml_string) do
          {:ok, frontmatter} when is_map(frontmatter) ->
            {:ok, frontmatter, String.trim(body)}

          {:ok, _other} ->
            {:error, :frontmatter_not_a_map}

          {:error, reason} ->
            {:error, {:yaml_parse_error, reason}}
        end

      _no_match ->
        {:error, :no_frontmatter}
    end
  end

  @doc """
  Validate a SkillDefinition. Returns `:ok` or `{:error, reason}`.
  """
  @spec validate_skill(SkillDefinition.t()) :: :ok | {:error, term()}
  def validate_skill(%SkillDefinition{} = skill) do
    with :ok <- validate_name_present(skill.name),
         :ok <- validate_description_present(skill.description),
         :ok <- validate_name_format(skill.name),
         :ok <- validate_body_present(skill.body) do
      :ok
    end
  end

  # --- Private ---

  defp build_skill_definition(frontmatter, body, path, skills_root) do
    name = frontmatter["name"]
    description = frontmatter["description"]
    domain = derive_domain(path, skills_root)

    if is_nil(name) or is_nil(description) do
      Logger.warning("Skill file missing required frontmatter fields (name, description)",
        path: path
      )

      nil
    else
      %SkillDefinition{
        name: name,
        description: description,
        domain: domain,
        handler: resolve_handler(frontmatter["handler"]),
        schedule: frontmatter["schedule"],
        tags: frontmatter["tags"] || [],
        author: frontmatter["author"],
        timezone: frontmatter["timezone"],
        body: body,
        path: path
      }
    end
  end

  defp build_domain_index(frontmatter, body, path, skills_root) do
    domain = frontmatter["domain"] || derive_domain(path, skills_root)
    description = frontmatter["description"] || ""

    %DomainIndex{
      domain: domain,
      description: description,
      body: body,
      path: path
    }
  end

  @doc false
  def derive_domain(file_path, skills_root) do
    file_path
    |> Path.relative_to(skills_root)
    |> Path.dirname()
    |> String.split("/")
    |> List.first()
  end

  defp resolve_handler(nil), do: nil

  defp resolve_handler(module_string) when is_binary(module_string) do
    try do
      String.to_existing_atom("Elixir." <> module_string)
    rescue
      ArgumentError -> nil
    end
  end

  defp resolve_handler(_), do: nil

  @reserved_commands ~w(all help)

  defp validate_name_present(nil), do: {:error, :missing_name}
  defp validate_name_present(""), do: {:error, :missing_name}
  defp validate_name_present(_), do: :ok

  defp validate_description_present(nil), do: {:error, :missing_description}
  defp validate_description_present(""), do: {:error, :missing_description}
  defp validate_description_present(_), do: :ok

  defp validate_name_format(name) do
    case String.split(name, ".", parts: 2) do
      [_domain, command] when command in @reserved_commands ->
        {:error, {:reserved_name, name, "'#{command}' is reserved by get_skill routing"}}

      [_domain, _command] ->
        if Regex.match?(~r/^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$/, name) do
          :ok
        else
          {:error,
           {:invalid_name, name,
            "expected format: domain.action (lowercase alphanumeric + underscore)"}}
        end

      _ ->
        {:error, {:invalid_name, name, "expected format: domain.action"}}
    end
  end

  defp validate_body_present(nil), do: {:error, :missing_body}
  defp validate_body_present(""), do: {:error, :missing_body}
  defp validate_body_present(_), do: :ok
end
