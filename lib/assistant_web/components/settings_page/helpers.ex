defmodule AssistantWeb.Components.SettingsPage.Helpers do
  @moduledoc false

  def nav_items do
    [
      {"workspace", "Chat"},
      {"profile", "Profile"},
      {"analytics", "Analytics"},
      {"memory", "Memory"},
      {"apps", "Apps & Connections"},
      {"approvals", "Approvals"},
      {"workflows", "Workflows"},
      {"help", "Help"},
      {"admin", "Admin"}
    ]
  end

  @doc """
  Returns nav items filtered by user role and scope privileges.
  Admin tab only shown to admins. Other sections gated by scope visibility.
  """
  def nav_items_for(current_scope) when is_map(current_scope) do
    is_admin = current_scope.admin?

    nav_items()
    |> Enum.filter(fn {section, _label} ->
      case section do
        "admin" -> is_admin
        _ -> scope_visible?(section_scope(section), current_scope)
      end
    end)
  end

  def nav_items_for(is_admin) when is_boolean(is_admin) do
    if is_admin do
      nav_items()
    else
      Enum.reject(nav_items(), fn {section, _label} -> section == "admin" end)
    end
  end

  @doc """
  Returns true if the given scope should be visible to the user.
  Admins see everything. Empty privileges = unrestricted (backwards compatible).
  """
  def scope_visible?(_scope_name, %{admin?: true}), do: true

  def scope_visible?(_scope_name, %{privileges: []}), do: true

  def scope_visible?(nil, _current_scope), do: true

  def scope_visible?(scope_name, %{privileges: privileges}) do
    scope_name in privileges
  end

  def scope_visible?(_scope_name, _current_scope), do: true

  @doc """
  Maps a settings section name to its access scope name.
  Returns nil for sections that don't require a specific scope.
  """
  def section_scope(section) do
    case section do
      "analytics" -> "analytics"
      "memory" -> "memory"
      "workflows" -> "workflows"
      "apps" -> "integrations"
      _ -> nil
    end
  end

  def icon_for(section) do
    case section do
      "profile" -> "hero-user-circle"
      "workspace" -> "hero-chat-bubble-left-right"
      "analytics" -> "hero-chart-bar"
      "memory" -> "hero-circle-stack"
      "apps" -> "hero-puzzle-piece"
      "approvals" -> "hero-shield-check"
      "workflows" -> "hero-command-line"
      "admin" -> "hero-cog-6-tooth"
      "help" -> "hero-question-mark-circle"
      _ -> "hero-question-mark-circle"
    end
  end

  def page_title(section) do
    case section do
      "profile" -> "Profile"
      "workspace" -> "Chat"
      "analytics" -> "Analytics"
      "memory" -> "Memory"
      "apps" -> "Apps & Connections"
      "approvals" -> "Approvals"
      "workflows" -> "Workflows"
      "admin" -> "Admin"
      "help" -> "Help & Setup"
      _ -> "Settings"
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

      is_list(tool_calls) and tool_calls != [] ->
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
