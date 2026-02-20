defmodule Assistant.Workflows do
  @moduledoc """
  Workflow management for the settings UI.

  Workflows are markdown files with YAML frontmatter stored in the workflows
  directory. This module provides list/get/update/duplicate operations and
  schedule conversions between user-friendly form values and cron.
  """

  require Logger

  alias Assistant.SkillPermissions
  alias Assistant.Skills.Loader
  alias Assistant.Skills.Registry
  alias Assistant.Skills.Workflow.Helpers

  @name_regex ~r/^[a-z][a-z0-9_-]*$/

  @ordered_frontmatter_keys ~w(
    name
    description
    cron
    channel
    enabled
    allowed_tools
    tags
  )

  @doc """
  Returns all workflows sorted by name.
  """
  @spec list_workflows() :: {:ok, [map()]} | {:error, term()}
  def list_workflows do
    dir = Helpers.resolve_workflows_dir()

    with {:ok, files} <- File.ls(dir) do
      workflows =
        files
        |> Enum.filter(&(String.ends_with?(&1, ".md") and &1 != ".gitkeep"))
        |> Enum.map(fn file -> load_workflow(Path.join(dir, file)) end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.name)

      {:ok, workflows}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Loads one workflow by name.
  """
  @spec get_workflow(String.t()) :: {:ok, map()} | {:error, term()}
  def get_workflow(name) when is_binary(name) do
    if Regex.match?(@name_regex, name) do
      path = workflow_path(name)

      case load_workflow(path) do
        nil -> {:error, :not_found}
        workflow -> {:ok, workflow}
      end
    else
      {:error, :invalid_name}
    end
  end

  @doc """
  Enables or disables a workflow.
  """
  @spec set_enabled(String.t(), boolean()) :: {:ok, map()} | {:error, term()}
  def set_enabled(name, enabled) when is_boolean(enabled) do
    with {:ok, workflow} <- get_workflow(name),
         {:ok, _path} <-
           persist(
             workflow.path,
             Map.put(workflow.frontmatter, "enabled", enabled),
             workflow.body
           ),
         :ok <- safe_reload_scheduler() do
      get_workflow(name)
    end
  end

  @doc """
  Creates a new blank workflow with a unique name.
  """
  @spec create_workflow() :: {:ok, map()} | {:error, term()}
  def create_workflow do
    name = "untitled-#{System.os_time(:second)}"
    path = workflow_path(name)

    frontmatter = %{
      "name" => name,
      "description" => "New workflow",
      "enabled" => false,
      "allowed_tools" => [],
      "tags" => []
    }

    with {:ok, _path} <- persist(path, frontmatter, "") do
      case load_workflow(path) do
        nil -> {:error, :write_failed}
        workflow -> {:ok, workflow}
      end
    end
  end

  @doc """
  Duplicates a workflow and returns the copied workflow.
  """
  @spec duplicate(String.t()) :: {:ok, map()} | {:error, term()}
  def duplicate(name) do
    with {:ok, workflow} <- get_workflow(name),
         {:ok, copy_name} <- next_copy_name(name),
         frontmatter <- workflow.frontmatter |> Map.put("name", copy_name),
         frontmatter <- Map.put(frontmatter, "description", "#{workflow.description} (Copy)"),
         {:ok, path} <- persist(workflow_path(copy_name), frontmatter, workflow.body),
         :ok <- safe_reload_scheduler() do
      case load_workflow(path) do
        nil -> {:error, :not_found}
        copied -> {:ok, copied}
      end
    end
  end

  @doc """
  Updates workflow metadata from settings form params.
  """
  @spec update_metadata(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_metadata(name, params) when is_map(params) do
    with {:ok, workflow} <- get_workflow(name),
         {:ok, cron} <- cron_from_schedule(params),
         frontmatter <- apply_metadata_params(workflow.frontmatter, params, cron),
         {:ok, _path} <- persist(workflow.path, frontmatter, workflow.body),
         :ok <- safe_reload_scheduler() do
      get_workflow(name)
    end
  end

  @doc """
  Updates workflow markdown body.
  """
  @spec update_body(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def update_body(name, body) when is_binary(body) do
    with {:ok, workflow} <- get_workflow(name),
         {:ok, _path} <- persist(workflow.path, workflow.frontmatter, body) do
      get_workflow(name)
    end
  end

  @doc """
  Returns available tools with user-friendly labels for UI selectors.
  """
  @spec available_tools() :: [map()]
  def available_tools do
    Registry.list_all()
    |> Enum.filter(fn skill -> SkillPermissions.enabled?(skill.name) end)
    |> Enum.map(fn skill ->
      %{
        id: skill.name,
        label: SkillPermissions.skill_label(skill.name),
        domain: SkillPermissions.domain_label(skill.domain)
      }
    end)
    |> Enum.sort_by(&{&1.domain, &1.label})
  end

  @doc """
  Returns a user-facing label for a tool identifier.
  """
  @spec display_label(String.t()) :: String.t()
  def display_label(skill_name) do
    SkillPermissions.skill_label(skill_name)
  end

  # --- Internal loading/persistence ---

  defp load_workflow(path) do
    with {:ok, content} <- File.read(path),
         {:ok, frontmatter, body} <- Loader.parse_frontmatter(content),
         {:ok, html, _messages} <- Earmark.as_html(body) do
      name = frontmatter["name"] || Path.basename(path, ".md")
      cron = frontmatter["cron"]
      schedule = schedule_from_cron(cron)

      %{
        name: name,
        description: frontmatter["description"] || "(no description)",
        channel: frontmatter["channel"] || "",
        cron: cron,
        schedule: schedule,
        schedule_label: humanize_schedule(schedule),
        enabled: frontmatter["enabled"] != false,
        allowed_tools: normalize_allowed_tools(frontmatter["allowed_tools"]),
        body: body,
        body_html: html,
        path: path,
        frontmatter: frontmatter
      }
    else
      _ -> nil
    end
  end

  defp persist(path, frontmatter, body) do
    File.mkdir_p!(Path.dirname(path))

    yaml =
      frontmatter
      |> normalize_frontmatter()
      |> encode_frontmatter()

    content = """
    ---
    #{yaml}---
    #{String.trim(body)}
    """

    case File.write(path, content) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_frontmatter(frontmatter) do
    ordered =
      @ordered_frontmatter_keys ++
        ((Map.keys(frontmatter) -- @ordered_frontmatter_keys) |> Enum.sort())

    Enum.reduce(ordered, %{}, fn key, acc ->
      case Map.get(frontmatter, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp encode_frontmatter(frontmatter) do
    frontmatter
    |> Enum.map(fn {key, value} -> encode_yaml_kv(key, value) end)
    |> Enum.join()
  end

  defp encode_yaml_kv(key, value) when is_list(value) do
    if value == [] do
      "#{key}: []\n"
    else
      items =
        value
        |> Enum.map_join("", fn item -> "  - #{yaml_string(item)}\n" end)

      "#{key}:\n#{items}"
    end
  end

  defp encode_yaml_kv(key, value) when is_boolean(value), do: "#{key}: #{value}\n"
  defp encode_yaml_kv(key, value) when is_integer(value), do: "#{key}: #{value}\n"
  defp encode_yaml_kv(key, value), do: "#{key}: #{yaml_string(value)}\n"

  defp yaml_string(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    ~s("#{escaped}")
  end

  defp apply_metadata_params(frontmatter, params, cron) do
    tools = normalize_allowed_tools(Map.get(params, "allowed_tools", []))

    frontmatter
    |> maybe_put("description", Map.get(params, "description"))
    |> maybe_put("channel", Map.get(params, "channel"))
    |> Map.put("cron", cron)
    |> Map.put("allowed_tools", tools)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_allowed_tools(tools) when is_list(tools) do
    tools
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_allowed_tools(_), do: []

  # --- Schedule conversion ---

  defp schedule_from_cron(nil) do
    %{
      recurrence: "daily",
      time: "09:00",
      day_of_week: "1",
      day_of_month: "1",
      custom_cron: ""
    }
  end

  defp schedule_from_cron(cron) do
    case String.split(cron, " ", parts: 5) do
      [minute, hour, "*", "*", "*"] ->
        %{
          recurrence: "daily",
          time: format_time_24(hour, minute),
          day_of_week: "1",
          day_of_month: "1",
          custom_cron: cron
        }

      [minute, hour, "*", "*", day] ->
        %{
          recurrence: "weekly",
          time: format_time_24(hour, minute),
          day_of_week: day,
          day_of_month: "1",
          custom_cron: cron
        }

      [minute, hour, dom, "*", "*"] ->
        %{
          recurrence: "monthly",
          time: format_time_24(hour, minute),
          day_of_week: "1",
          day_of_month: dom,
          custom_cron: cron
        }

      _ ->
        %{
          recurrence: "custom",
          time: "09:00",
          day_of_week: "1",
          day_of_month: "1",
          custom_cron: cron
        }
    end
  end

  defp cron_from_schedule(params) do
    recurrence = Map.get(params, "recurrence", "daily")
    time = Map.get(params, "time", "09:00")
    {hour, minute} = parse_time(time)

    case recurrence do
      "daily" ->
        {:ok, "#{minute} #{hour} * * *"}

      "weekly" ->
        day = Map.get(params, "day_of_week", "1")
        {:ok, "#{minute} #{hour} * * #{day}"}

      "monthly" ->
        day = Map.get(params, "day_of_month", "1")
        {:ok, "#{minute} #{hour} #{day} * *"}

      "custom" ->
        custom = Map.get(params, "custom_cron", "")

        if custom == "" do
          {:error, :missing_custom_cron}
        else
          {:ok, custom}
        end

      _ ->
        {:ok, "#{minute} #{hour} * * *"}
    end
  end

  defp parse_time(time) do
    case String.split(time, ":", parts: 2) do
      [hour, minute] -> {parse_int(hour, 9), parse_int(minute, 0)}
      _ -> {9, 0}
    end
  end

  defp parse_int(value, default) do
    case Integer.parse(value) do
      {parsed, _rest} -> parsed
      :error -> default
    end
  end

  defp format_time_24(hour, minute) do
    h = String.pad_leading(to_string(hour), 2, "0")
    m = String.pad_leading(to_string(minute), 2, "0")
    "#{h}:#{m}"
  end

  defp humanize_schedule(%{recurrence: "daily", time: time}) do
    "Daily at #{format_time_12(time)}"
  end

  defp humanize_schedule(%{recurrence: "weekly", time: time, day_of_week: day}) do
    "Weekly on #{weekday_label(day)} at #{format_time_12(time)}"
  end

  defp humanize_schedule(%{recurrence: "monthly", time: time, day_of_month: day}) do
    "Monthly on day #{day} at #{format_time_12(time)}"
  end

  defp humanize_schedule(%{recurrence: "custom", custom_cron: cron}), do: cron
  defp humanize_schedule(_), do: "Unscheduled"

  defp format_time_12(time) do
    {hour, minute} = parse_time(time)
    suffix = if hour >= 12, do: "PM", else: "AM"

    hour_12 =
      case rem(hour, 12) do
        0 -> 12
        h -> h
      end

    "#{hour_12}:#{String.pad_leading(to_string(minute), 2, "0")} #{suffix}"
  end

  defp weekday_label(day) do
    case to_string(day) do
      "0" -> "Sunday"
      "1" -> "Monday"
      "2" -> "Tuesday"
      "3" -> "Wednesday"
      "4" -> "Thursday"
      "5" -> "Friday"
      "6" -> "Saturday"
      _ -> "Monday"
    end
  end

  defp next_copy_name(name) do
    try_name = "#{name}-copy"

    if File.exists?(workflow_path(try_name)) do
      next_copy_name(name, 2)
    else
      {:ok, try_name}
    end
  end

  defp next_copy_name(name, idx) do
    try_name = "#{name}-copy-#{idx}"

    if File.exists?(workflow_path(try_name)) do
      next_copy_name(name, idx + 1)
    else
      {:ok, try_name}
    end
  end

  defp workflow_path(name) do
    Path.join(Helpers.resolve_workflows_dir(), "#{name}.md")
  end

  defp safe_reload_scheduler do
    try do
      Assistant.Scheduler.QuantumLoader.reload()
      :ok
    rescue
      exception ->
        Logger.warning("Failed to reload scheduler after workflow update",
          reason: Exception.message(exception)
        )

        :ok
    catch
      :exit, _reason -> :ok
    end
  end
end
