defmodule AssistantWeb.Components.SettingsPage.Helpers do
  @moduledoc false

  def nav_items do
    [
      {"profile", "Profile"},
      {"models", "Models"},
      {"analytics", "Analytics"},
      {"memory", "Memory"},
      {"apps", "Apps & Connections"},
      {"workflows", "Workflows"},
      {"skills", "Skill Permissions"},
      {"help", "Help"}
    ]
  end

  def icon_for(section) do
    case section do
      "profile" -> "hero-user-circle"
      "models" -> "hero-cube"
      "analytics" -> "hero-chart-bar"
      "memory" -> "hero-document-text"
      "apps" -> "hero-puzzle-piece"
      "workflows" -> "hero-command-line"
      "skills" -> "hero-wrench-screwdriver"
      "help" -> "hero-question-mark-circle"
    end
  end

  def page_title(section) do
    case section do
      "profile" -> "Profile"
      "models" -> "Models"
      "analytics" -> "Analytics"
      "memory" -> "Memory"
      "apps" -> "Apps & Connections"
      "workflows" -> "Workflows"
      "skills" -> "Skill Permissions"
      "help" -> "Help & Setup"
    end
  end

  def filtered_help_articles(help_articles, help_query) do
    query = help_query |> to_string() |> String.trim() |> String.downcase()

    if query == "" do
      help_articles
    else
      Enum.filter(help_articles, fn article ->
        haystack = String.downcase("#{article.title} #{article.summary}")
        String.contains?(haystack, query)
      end)
    end
  end

  def format_time(nil), do: "Unknown"

  def format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  def format_time(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  def format_time(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, dt, _offset} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
      _ -> iso8601
    end
  end

  def short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  def short_id(_), do: "unknown"

  def display_message_content(message) do
    content = Map.get(message, :content) || Map.get(message, "content")
    tool_calls = Map.get(message, :tool_calls) || Map.get(message, "tool_calls")
    tool_results = Map.get(message, :tool_results) || Map.get(message, "tool_results")

    cond do
      is_binary(content) and String.trim(content) != "" ->
        content

      is_map(tool_calls) ->
        "Tool calls: " <> Jason.encode!(tool_calls)

      is_map(tool_results) ->
        "Tool results: " <> Jason.encode!(tool_results)

      true ->
        "(no content)"
    end
  end

  def format_importance(%Decimal{} = value), do: value |> Decimal.to_float() |> Float.round(2)
  def format_importance(value) when is_float(value), do: Float.round(value, 2)
  def format_importance(value) when is_integer(value), do: value
  def format_importance(_), do: "-"

  def format_tags(tags) when is_list(tags) do
    tags
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [] -> "-"
      values -> Enum.join(values, ", ")
    end
  end

  def format_tags(_), do: "-"

  def humanize(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" ->
        "-"

      trimmed ->
        trimmed
        |> String.replace("_", " ")
        |> String.split()
        |> Enum.map_join(" ", &String.capitalize/1)
    end
  end

  def humanize(value) when is_atom(value), do: value |> Atom.to_string() |> humanize()
  def humanize(nil), do: "-"
  def humanize(value), do: to_string(value) |> humanize()

  def profile_first_name(profile) when is_map(profile) do
    profile
    |> Map.get("display_name", "")
    |> to_string()
    |> String.trim()
    |> case do
      "" ->
        "there"

      full_name ->
        full_name
        |> String.split()
        |> List.first()
    end
  end

  def profile_first_name(_), do: "there"
end
