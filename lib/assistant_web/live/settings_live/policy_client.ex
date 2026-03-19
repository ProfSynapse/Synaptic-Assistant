defmodule AssistantWeb.SettingsLive.PolicyClient do
  @moduledoc false

  @default_presets ["permissive", "default", "strict"]

  def list_pending_approvals(settings_user) do
    call_or_default(:list_pending_approvals, [settings_user], {:error, :not_available})
  end

  def resolve_approval(settings_user, approval_id, effect) do
    call_or_default(
      :resolve_approval,
      [settings_user, approval_id, effect],
      {:error, :not_available}
    )
  end

  def policy_presets do
    call_or_default(:policy_presets, [], {:ok, @default_presets})
  end

  def current_preset(current_scope) do
    call_or_default(:current_preset, [current_scope], {:error, :not_available})
  end

  def list_policy_rules(current_scope) do
    call_or_default(:list_policy_rules, [current_scope], {:error, :not_available})
  end

  def apply_preset(current_scope, preset) do
    call_or_default(:apply_preset, [current_scope, preset], {:error, :not_available})
  end

  defp call_or_default(fun, args, default) do
    module = policy_module()

    cond do
      module && function_exported?(module, fun, length(args)) ->
        try do
          apply(module, fun, args)
        rescue
          _ -> default
        end

      true ->
        default
    end
  end

  defp policy_module do
    if Code.ensure_loaded?(Assistant.Policy) do
      Assistant.Policy
    else
      nil
    end
  end
end
