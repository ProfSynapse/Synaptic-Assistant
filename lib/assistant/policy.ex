defmodule Assistant.Policy do
  @moduledoc """
  Context for deterministic policy decisions (allow/ask/deny).
  """

  alias Assistant.Policy.Resolver
  alias Assistant.Schemas.{PolicyApproval, PolicyRule}
  alias Assistant.Repo

  import Ecto.Query

  @preset_definitions %{
    "permissive" => %{
      description: "Allow safe reads and trusted writes.",
      rules: [
        %{
          resource_type: "skill_call",
          effect: "allow",
          matchers: %{"action_class" => "read"},
          priority: 10
        }
      ]
    },
    "default" => %{
      description: "Ask for external writes, allow reads.",
      rules: [
        %{
          resource_type: "skill_call",
          effect: "ask",
          matchers: %{"action_class" => ["external_write", "destructive"]},
          priority: 10
        }
      ]
    },
    "strict" => %{
      description: "Deny destructive actions, ask on writes.",
      rules: [
        %{
          resource_type: "skill_call",
          effect: "deny",
          matchers: %{"action_class" => "destructive"},
          priority: 5
        },
        %{
          resource_type: "skill_call",
          effect: "ask",
          matchers: %{"action_class" => "external_write"},
          priority: 15
        }
      ]
    }
  }

  @doc """
  List all policy rules ordered by scope priority and numeric priority.
  """
  def list_rules do
    PolicyRule |> order_by([r], asc: r.priority) |> Repo.all()
  end

  @doc """
  Creates a policy rule.
  """
  @spec create_rule(map()) :: {:ok, PolicyRule.t()} | {:error, Ecto.Changeset.t()}
  def create_rule(attrs) do
    %PolicyRule{}
    |> PolicyRule.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Resolves an action descriptor to `{:ok, effect, matching_rule}`.
  """
  @spec resolve_action(map(), keyword()) :: {:ok, atom(), PolicyRule.t() | nil}
  def resolve_action(action, opts \\ []) do
    rules = Keyword.get(opts, :rules, list_rules())
    scope = Keyword.get(opts, :scope, %{})

    Resolver.resolve(action, rules: rules, scope: scope)
  end

  @doc """
  List policy rules filtered by scope descriptor.
  """
  @spec list_policy_rules(nil | :system | {:workspace, binary()} | {:user, binary()}) :: [
          PolicyRule.t()
        ]
  def list_policy_rules(nil), do: list_rules()

  def list_policy_rules(:system) do
    PolicyRule |> where([r], r.scope_type == "system") |> Repo.all()
  end

  def list_policy_rules({:workspace, workspace_id}) do
    PolicyRule
    |> where([r], r.scope_type == "workspace" and r.scope_id == ^workspace_id)
    |> order_by([r], desc: r.priority)
    |> Repo.all()
  end

  def list_policy_rules({:user, user_id}) do
    PolicyRule
    |> where([r], r.scope_type == "user" and r.scope_id == ^user_id)
    |> order_by([r], desc: r.priority)
    |> Repo.all()
  end

  @doc """
  Returns the available policy preset metadata.
  """
  def policy_presets do
    Map.new(@preset_definitions, fn {name, meta} ->
      {name, meta.description}
    end)
  end

  @doc """
  Claims the current preset for a workspace.
  """
  def current_preset(workspace_id) when is_binary(workspace_id) do
    last =
      PolicyRule
      |> where(
        [r],
        r.scope_type == "workspace" and r.scope_id == ^workspace_id and
          ilike(r.source, ^"preset:%")
      )
      |> order_by([r], desc: r.inserted_at)
      |> limit(1)
      |> Repo.one()

    case last do
      %PolicyRule{source: "preset:" <> name} -> name
      _ -> "default"
    end
  end

  @doc """
  Apply a preset by seeding predefined rules for the workspace.
  """
  @spec apply_preset(String.t() | atom(), binary()) :: {:ok, [PolicyRule.t()]} | {:error, term()}
  def apply_preset(preset, workspace_id) when is_binary(workspace_id) do
    preset_key = to_string(preset)

    case Map.get(@preset_definitions, preset_key) do
      nil ->
        {:error, :unknown_preset}

      %{rules: rules} ->
        Repo.transaction(fn ->
          from(r in PolicyRule,
            where:
              r.scope_type == "workspace" and r.scope_id == ^workspace_id and
                ilike(r.source, ^"preset:%")
          )
          |> Repo.delete_all()

          inserted =
            Enum.map(rules, fn rule ->
              attrs =
                rule
                |> Map.put(:scope_type, "workspace")
                |> Map.put(:scope_id, workspace_id)
                |> Map.put(:source, "preset:#{preset_key}")

              {:ok, inserted} =
                %PolicyRule{}
                |> PolicyRule.changeset(attrs)
                |> Repo.insert()

              inserted
            end)

          inserted
        end)
    end
  end

  @doc """
  Lists pending approvals for a user.
  """
  def list_pending_approvals(user_id) when is_binary(user_id) do
    now = DateTime.utc_now()

    PolicyApproval
    |> where([a], a.user_id == ^user_id)
    |> where([a], is_nil(a.expires_at) or a.expires_at >= ^now)
    |> order_by([a], desc: a.inserted_at)
    |> Repo.all()
  end

  @doc """
  Records an approval decision for an action (user + rule).
  """
  @spec resolve_approval(binary(), binary(), atom()) ::
          {:ok, PolicyApproval.t()} | {:error, Ecto.Changeset.t()}
  def resolve_approval(user_id, rule_id, effect) when is_binary(user_id) and is_binary(rule_id) do
    rule = Repo.get(PolicyRule, rule_id)

    attrs = %{
      user_id: user_id,
      rule_id: rule_id,
      resource_type: rule && rule.resource_type,
      effect: to_string(effect)
    }

    create_approval(attrs)
  end

  @doc """
  Records an approval decision for future reference/audit.
  """
  @spec create_approval(map()) ::
          {:ok, PolicyApproval.t()} | {:error, Ecto.Changeset.t()}
  def create_approval(attrs) do
    %PolicyApproval{}
    |> PolicyApproval.changeset(attrs)
    |> Repo.insert()
  end
end
