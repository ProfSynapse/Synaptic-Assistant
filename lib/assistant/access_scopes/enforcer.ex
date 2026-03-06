# lib/assistant/access_scopes/enforcer.ex — Scope-based skill access enforcement.
#
# Checks whether a chat user is allowed to invoke a given skill based on the
# access_scopes assigned to their linked settings_user. Wired into
# sub_agent.ex execute_use_skill/6 cond chain, BEFORE the SkillPermissions check.
#
# Key rules:
#   - nil/unknown user_id → allow (system/internal calls)
#   - No linked settings_user → allow (backwards compat)
#   - Admin settings_user → always allow
#   - Empty access_scopes → unrestricted (backwards compat)
#   - Otherwise, skill's domain must map to a scope the user has

defmodule Assistant.AccessScopes.Enforcer do
  @moduledoc false

  alias Assistant.Accounts

  require Logger

  # Maps access scope names to the skill domain prefixes they grant.
  # Skill names follow the pattern "domain.action" (e.g., "email.send").
  @scope_to_skill_domains %{
    "chat" => ["agents", "tasks", "web", "images"],
    "integrations" => ["email", "calendar", "files", "hubspot"],
    "workflows" => ["workflow"],
    "memory" => ["memory"]
  }

  @spec skill_allowed?(String.t() | nil, String.t()) :: boolean()
  def skill_allowed?(user_id, skill_name)

  def skill_allowed?(nil, _skill_name), do: true
  def skill_allowed?("unknown", _skill_name), do: true

  def skill_allowed?(user_id, skill_name) do
    case cached_settings_user(user_id) do
      nil -> true
      settings_user -> authorized?(settings_user, skill_name)
    end
  end

  defp authorized?(%{is_admin: true}, _skill_name), do: true

  defp authorized?(settings_user, skill_name) do
    scopes = settings_user.access_scopes || []

    if scopes == [] do
      true
    else
      domain = skill_domain(skill_name)
      required_scope = scope_for_domain(domain)

      case required_scope do
        nil ->
          Logger.info("Skill denied — unmapped domain has no access scope",
            skill_name: skill_name,
            domain: domain
          )

          false

        scope ->
          scope in scopes
      end
    end
  end

  # Per-process cache for settings_user lookups. Within a single request
  # (sub-agent LLM loop iteration), multiple skill calls share the same
  # process, so this avoids repeated DB queries for the same user_id.
  defp cached_settings_user(user_id) do
    cache_key = {:access_scope_user, user_id}

    case Process.get(cache_key) do
      nil ->
        result = Accounts.get_settings_user_by_user_id(user_id)
        Process.put(cache_key, {:cached, result})
        result

      {:cached, result} ->
        result
    end
  end

  defp skill_domain(skill_name) do
    case String.split(skill_name, ".", parts: 2) do
      [domain, _action] -> domain
      _ -> nil
    end
  end

  defp scope_for_domain(domain) do
    Enum.find_value(@scope_to_skill_domains, fn {scope, domains} ->
      if domain in domains, do: scope
    end)
  end
end
