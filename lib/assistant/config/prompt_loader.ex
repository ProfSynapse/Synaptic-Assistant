# lib/assistant/config/prompt_loader.ex — Prompt template loader for config/prompts/*.yaml.
#
# ETS-backed GenServer that loads, caches, and hot-reloads system prompt
# templates from YAML files. Public API functions read compiled EEx
# templates from ETS for lock-free concurrent access, then render them
# with per-conversation variables (current_date, skill_catalog, etc.).
#
# Follows the same GenServer/ETS pattern as Assistant.Config.Loader.
#
# Related files:
#   - config/prompts/*.yaml (source of truth for system prompts)
#   - lib/assistant/config/loader.ex (sibling config loader, same pattern)
#   - lib/assistant/orchestrator/context.ex (consumer — orchestrator prompt)
#   - lib/assistant/orchestrator/sub_agent.ex (consumer — sub-agent prompt)

defmodule Assistant.Config.PromptLoader do
  @moduledoc """
  Loads and serves system prompt templates from config/prompts/*.yaml.

  Backed by ETS for fast concurrent reads. Templates are compiled once via
  EEx at load time and rendered per-call with runtime variables.

  ## Public API

  - `render/2` — Render a prompt template with variable bindings.
  - `render_section/3` — Render a named section from a prompt file.
  - `get_raw/1` — Return the raw (unrendered) template string.
  - `reload/0` — Re-read all YAML files from disk.

  ## Boot Behaviour

  If `config/prompts/` is missing or empty, `init/1` logs a warning but
  does NOT crash — the assistant can operate with hardcoded fallbacks.
  Individual malformed YAML files are skipped with a warning.

  ## Hot Reload

  Call `reload/0` (or let `Config.Watcher` call it) to re-read all prompt
  files. If a file is invalid, the previous template for that prompt is
  kept and a warning is logged.

  ## Template Variables

  Templates use EEx syntax (`<%= @var %>`). Common variables:
  - `current_date` — ISO 8601 date string
  - `skill_domains` — Comma-separated list of available skill domains
  - `user_id` — Current user identifier
  - `channel` — Current channel identifier
  - `skills_text` — Comma-separated list of skills (sub-agent)
  - `dep_section` — Dependency results text (sub-agent)
  - `context_section` — Additional context text (sub-agent)
  """

  use GenServer

  require Logger

  @ets_table :assistant_prompts
  @prompts_dir "config/prompts"

  # --- Public API (read from ETS, render with EEx) ---

  @doc """
  Renders a prompt template with the given variable bindings.

  The `name` corresponds to the YAML filename without extension
  (e.g., `:orchestrator` for `config/prompts/orchestrator.yaml`).

  The `system:` key from the YAML is rendered by default.

  ## Parameters

    * `name` - Prompt name as an atom (e.g., `:orchestrator`, `:sub_agent`)
    * `assigns` - Map of variable bindings for EEx rendering

  ## Returns

    * `{:ok, rendered_string}` — Successfully rendered prompt
    * `{:error, :not_found}` — No prompt loaded with that name
    * `{:error, {:render_failed, reason}}` — EEx rendering failed

  ## Examples

      iex> PromptLoader.render(:orchestrator, %{
      ...>   current_date: "2026-02-18",
      ...>   skill_domains: "calendar, email, tasks",
      ...>   user_id: "user_123",
      ...>   channel: "slack"
      ...> })
      {:ok, "You are an AI assistant orchestrator..."}
  """
  @spec render(atom(), map()) :: {:ok, String.t()} | {:error, term()}
  def render(name, assigns \\ %{}) do
    case lookup_template(name, :system) do
      {:ok, template} ->
        render_template(template, assigns)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Renders a named section from a prompt file.

  Some prompt files contain a `sections:` map with named sub-templates
  (e.g., memory.yaml has topic_extraction, summary_generation, etc.).

  ## Parameters

    * `name` - Prompt name as an atom (e.g., `:memory`)
    * `section` - Section name as an atom (e.g., `:topic_extraction`)
    * `assigns` - Map of variable bindings for EEx rendering

  ## Returns

    * `{:ok, rendered_string}` — Successfully rendered section
    * `{:error, :not_found}` — No prompt or section with that name
    * `{:error, {:render_failed, reason}}` — EEx rendering failed
  """
  @spec render_section(atom(), atom(), map()) :: {:ok, String.t()} | {:error, term()}
  def render_section(name, section, assigns \\ %{}) do
    case lookup_template(name, {:section, section}) do
      {:ok, template} ->
        render_template(template, assigns)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Returns the raw (unrendered) system template string for a prompt.

  Useful for debugging or when the caller wants to handle rendering
  themselves.

  ## Returns

    * `{:ok, raw_template}` — The raw EEx template string
    * `{:error, :not_found}` — No prompt loaded with that name
  """
  @spec get_raw(atom()) :: {:ok, String.t()} | {:error, :not_found}
  def get_raw(name) do
    case :ets.lookup(@ets_table, {name, :raw_system}) do
      [{_, raw}] -> {:ok, raw}
      [] -> {:error, :not_found}
    end
  end

  # --- Reload API (goes through GenServer for coordination) ---

  @doc """
  Reloads all prompt templates from disk. Called by Config.Watcher on file change.
  """
  @spec reload() :: :ok | {:error, term()}
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  # --- GenServer ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    dir = Keyword.get(opts, :dir, @prompts_dir)
    table = :ets.new(@ets_table, [:named_table, :set, :public, read_concurrency: true])

    load_all(dir, table)

    {:ok, %{dir: dir, table: table}}
  end

  @impl true
  def handle_call(:reload, _from, %{dir: dir, table: table} = state) do
    load_all(dir, table)
    Logger.info("Prompt templates reloaded from #{dir}")
    {:reply, :ok, state}
  end

  # --- Internal: Loading ---

  defp load_all(dir, table) do
    case File.ls(dir) do
      {:ok, files} ->
        yaml_files = Enum.filter(files, &String.ends_with?(&1, ".yaml"))

        Enum.each(yaml_files, fn file ->
          name = file |> String.replace_suffix(".yaml", "") |> String.to_atom()
          path = Path.join(dir, file)
          load_prompt_file(name, path, table)
        end)

        :ets.insert(table, {:loaded_at, DateTime.utc_now()})

        Logger.info("Loaded #{length(yaml_files)} prompt template(s) from #{dir}",
          prompts: Enum.map(yaml_files, &String.replace_suffix(&1, ".yaml", ""))
        )

      {:error, reason} ->
        Logger.warning("Prompt directory not found or unreadable: #{dir}",
          reason: inspect(reason)
        )
    end
  end

  defp load_prompt_file(name, path, table) do
    with {:ok, raw} <- File.read(path),
         {:ok, parsed} <- parse_yaml(raw) do
      # Store compiled system template
      case parsed["system"] do
        nil ->
          Logger.warning("Prompt file #{path} has no 'system' key — skipping")

        system_text when is_binary(system_text) ->
          compiled = EEx.compile_string(system_text)
          :ets.insert(table, {{name, :system}, compiled})
          :ets.insert(table, {{name, :raw_system}, system_text})
      end

      # Store compiled section templates
      case parsed["sections"] do
        nil ->
          :ok

        sections when is_map(sections) ->
          Enum.each(sections, fn {section_name, section_text} when is_binary(section_text) ->
            section_atom = String.to_atom(section_name)
            compiled = EEx.compile_string(section_text)
            :ets.insert(table, {{name, {:section, section_atom}}, compiled})
            :ets.insert(table, {{name, {:raw_section, section_atom}}, section_text})
          end)

        _ ->
          Logger.warning("Prompt file #{path} has invalid 'sections' value — expected map")
      end

      :ok
    else
      {:error, reason} ->
        Logger.warning("Failed to load prompt file #{path}: #{inspect(reason)}")
        :error
    end
  end

  defp parse_yaml(yaml_string) do
    case YamlElixir.read_from_string(yaml_string) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, reason} -> {:error, {:yaml_parse_error, reason}}
    end
  end

  # --- Internal: Template Rendering ---

  defp lookup_template(name, key) do
    case :ets.lookup(@ets_table, {name, key}) do
      [{_, compiled}] -> {:ok, compiled}
      [] -> {:error, :not_found}
    end
  end

  defp render_template(compiled_template, assigns) do
    try do
      # Convert map keys to keyword list for EEx binding
      binding = Enum.map(assigns, fn {k, v} -> {to_atom(k), v} end)
      {result, _binding} = Code.eval_quoted(compiled_template, assigns: binding)
      {:ok, result}
    rescue
      e ->
        {:error, {:render_failed, Exception.message(e)}}
    end
  end

  defp to_atom(key) when is_atom(key), do: key
  defp to_atom(key) when is_binary(key), do: String.to_atom(key)
end
