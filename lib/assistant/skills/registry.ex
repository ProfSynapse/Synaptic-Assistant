# lib/assistant/skills/registry.ex — ETS-backed skill registry.
#
# GenServer that owns an ETS table for O(1) skill lookups. Reads
# go directly to ETS (no GenServer bottleneck). Writes go through
# the GenServer to maintain consistency. Populated at startup by the
# Loader and updated on hot-reload events from the Watcher.

defmodule Assistant.Skills.Registry do
  @moduledoc """
  ETS-backed registry for skill definitions and domain indexes.

  On startup, loads all skill markdown files from the configured
  skills directory via `Assistant.Skills.Loader`. The ETS table
  is keyed by skill name (dot notation, e.g., "email.send") for
  O(1) lookups. Domain indexes (SKILL.md files) are stored under
  `{:domain_index, domain}` keys.

  Public read functions hit ETS directly — no GenServer bottleneck.
  Write operations (reload, remove) go through the GenServer process.
  """

  use GenServer

  alias Assistant.Skills.{DomainIndex, Loader, SkillDefinition}

  require Logger

  @table_name :assistant_skills

  # --- Public API (reads go directly to ETS) ---

  @doc """
  Look up a skill by its dot-notation name (e.g., "email.send").
  """
  @spec lookup(String.t()) :: {:ok, SkillDefinition.t()} | {:error, :not_found}
  def lookup(name) do
    case :ets.lookup(@table_name, name) do
      [{^name, skill}] -> {:ok, skill}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Check if a skill with the given name exists.
  """
  @spec skill_exists?(String.t()) :: boolean()
  def skill_exists?(name) do
    :ets.member(@table_name, name)
  end

  @doc """
  Get a domain index (SKILL.md) by domain name.
  """
  @spec get_domain_index(String.t()) :: {:ok, DomainIndex.t()} | {:error, :not_found}
  def get_domain_index(domain) do
    case :ets.lookup(@table_name, {:domain_index, domain}) do
      [{{:domain_index, ^domain}, index}] -> {:ok, index}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  List all domain indexes, sorted by domain name.
  """
  @spec list_domain_indexes() :: [DomainIndex.t()]
  def list_domain_indexes do
    case :ets.lookup(@table_name, :domain_indexes) do
      [{:domain_indexes, indexes}] -> Enum.sort_by(indexes, & &1.domain)
      [] -> []
    end
  end

  @doc """
  List all skills in a specific domain.
  """
  @spec list_by_domain(String.t()) :: [SkillDefinition.t()]
  def list_by_domain(domain) do
    case :ets.lookup(@table_name, :skill_by_domain) do
      [{:skill_by_domain, index}] -> Map.get(index, domain, [])
      [] -> []
    end
  end

  @doc """
  List all registered skills.
  """
  @spec list_all() :: [SkillDefinition.t()]
  def list_all do
    case :ets.lookup(@table_name, :skill_by_domain) do
      [{:skill_by_domain, index}] -> index |> Map.values() |> List.flatten()
      [] -> []
    end
  end

  @doc """
  Search skills by name substring or tag.
  """
  @spec search(String.t()) :: [SkillDefinition.t()]
  def search(query) do
    query_lower = String.downcase(query)

    list_all()
    |> Enum.filter(fn skill ->
      String.contains?(String.downcase(skill.name), query_lower) or
        String.contains?(String.downcase(skill.description), query_lower) or
        Enum.any?(skill.tags, &String.contains?(String.downcase(&1), query_lower))
    end)
  end

  # --- GenServer API (for writes) ---

  @doc """
  Reload a single skill file. Called by the Watcher on file changes.
  """
  @spec reload_skill(String.t()) :: :ok
  def reload_skill(path) do
    GenServer.cast(__MODULE__, {:reload_skill, path})
  end

  @doc """
  Remove a skill by its file path. Called by the Watcher on file deletion.
  """
  @spec remove_skill(String.t()) :: :ok
  def remove_skill(path) do
    GenServer.cast(__MODULE__, {:remove_skill, path})
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    skills_dir = Keyword.get(opts, :skills_dir, default_skills_dir())
    table = :ets.new(@table_name, [:named_table, :set, :protected, read_concurrency: true])

    {skills, domain_indexes} = Loader.load_all(skills_dir)
    populate_table(table, skills, domain_indexes)

    Logger.info("Skill registry initialized",
      skill_count: length(skills),
      domain_count: length(domain_indexes)
    )

    {:ok, %{table: table, skills_dir: skills_dir}}
  end

  @impl true
  def handle_cast({:reload_skill, path}, state) do
    if Path.basename(path) == "SKILL.md" do
      case Loader.load_domain_index(path, state.skills_dir) do
        nil ->
          :ok

        index ->
          :ets.insert(state.table, {{:domain_index, index.domain}, index})
          rebuild_domain_indexes(state)
          Logger.info("Reloaded domain index", domain: index.domain, path: path)
      end
    else
      case Loader.load_skill_file(path, state.skills_dir) do
        nil ->
          :ok

        skill ->
          case Loader.validate_skill(skill) do
            :ok ->
              :ets.insert(state.table, {skill.name, skill})
              rebuild_skill_indexes(state)
              Logger.info("Reloaded skill", skill: skill.name, path: path)

            {:error, reason} ->
              Logger.warning("Invalid skill file on reload",
                path: path,
                reason: inspect(reason)
              )
          end
      end
    end

    {:noreply, state}
  end

  def handle_cast({:remove_skill, path}, state) do
    # Find and remove any skill that was loaded from this path
    all_skills = list_all()

    case Enum.find(all_skills, &(&1.path == path)) do
      nil ->
        :ok

      skill ->
        :ets.delete(state.table, skill.name)
        rebuild_skill_indexes(state)
        Logger.info("Removed skill", skill: skill.name, path: path)
    end

    {:noreply, state}
  end

  # --- Private ---

  defp populate_table(table, skills, domain_indexes) do
    # Register individual skills by name
    for skill <- skills do
      :ets.insert(table, {skill.name, skill})
    end

    # Register domain index files (SKILL.md)
    for index <- domain_indexes do
      :ets.insert(table, {{:domain_index, index.domain}, index})
    end

    # Build and store derived indexes
    store_skill_indexes(table, skills)
    store_domain_index_list(table, domain_indexes)
  end

  defp store_skill_indexes(table, skills) do
    skill_by_domain = Enum.group_by(skills, & &1.domain)
    :ets.insert(table, {:skill_by_domain, skill_by_domain})
  end

  defp store_domain_index_list(table, domain_indexes) do
    :ets.insert(table, {:domain_indexes, domain_indexes})
  end

  defp rebuild_skill_indexes(state) do
    # Collect all current skills from ETS (exclude meta keys)
    skills =
      :ets.tab2list(state.table)
      |> Enum.filter(fn
        {name, %SkillDefinition{}} when is_binary(name) -> true
        _ -> false
      end)
      |> Enum.map(fn {_name, skill} -> skill end)

    store_skill_indexes(state.table, skills)
  end

  defp rebuild_domain_indexes(state) do
    indexes =
      :ets.tab2list(state.table)
      |> Enum.filter(fn
        {{:domain_index, _}, %DomainIndex{}} -> true
        _ -> false
      end)
      |> Enum.map(fn {_key, index} -> index end)

    store_domain_index_list(state.table, indexes)
  end

  defp default_skills_dir do
    Application.get_env(:assistant, :skills_dir, Path.join(:code.priv_dir(:assistant), "skills"))
  end
end
