defmodule Assistant.PolicyTest do
  use Assistant.DataCase

  alias Assistant.Policy
  alias Assistant.Policy.Action

  describe "resolve_action/2" do
    test "returns rule-matched effect" do
      {:ok, rule} =
        Policy.create_rule(%{
          scope_type: "system",
          resource_type: "skill_call",
          effect: "ask",
          matchers: %{"skill" => "email.send"}
        })

      action = Action.skill_call("email.send")

      assert {:ok, :ask, ^rule} = Policy.resolve_action(action)
    end

    test "defaults to allow when no rules match" do
      action = Action.skill_call("tasks.search")

      assert {:ok, :allow, nil} = Policy.resolve_action(action)
    end

    test "workspace-specific rule overrides system rule" do
      {:ok, _system_rule} =
        Policy.create_rule(%{
          scope_type: "system",
          resource_type: "skill_call",
          effect: "allow",
          matchers: %{"skill" => "email.send"}
        })

      {:ok, workspace_rule} =
        Policy.create_rule(%{
          scope_type: "workspace",
          scope_id: Ecto.UUID.generate(),
          resource_type: "skill_call",
          effect: "deny",
          priority: 0,
          matchers: %{"skill" => "email.send"}
        })

      action = Action.skill_call("email.send")

      assert {:ok, :deny, ^workspace_rule} =
               Policy.resolve_action(action, scope: %{workspace_id: workspace_rule.scope_id})
    end

    test "policy presets and workspace rules operate" do
      workspace_id = Ecto.UUID.generate()
      assert Map.has_key?(Policy.policy_presets(), "default")
      assert {:ok, inserted} = Policy.apply_preset("permissive", workspace_id)
      assert "permissive" == Policy.current_preset(workspace_id)
      assert Enum.all?(inserted, &(&1.scope_id == workspace_id))

      assert Enum.all?(
               Policy.list_policy_rules({:workspace, workspace_id}),
               &(&1.scope_id == workspace_id)
             )
    end

    test "pending approvals honor resolves" do
      user_id = Ecto.UUID.generate()

      {:ok, rule} =
        Policy.create_rule(%{
          scope_type: "system",
          resource_type: "skill_call",
          effect: "ask"
        })

      assert {:ok, approval} = Policy.resolve_approval(user_id, rule.id, :allow)
      assert approval.effect == "allow"
      assert [approval] = Policy.list_pending_approvals(user_id)
    end
  end
end
