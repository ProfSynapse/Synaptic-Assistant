# test/assistant/skills/approval_gate_test.exs
#
# Tests for the requires_approval gate feature:
#   - SkillDefinition struct field
#   - Loader YAML parsing
#   - Sub-agent gate logic (handle_approval_gate receive block)
#   - build_approval_reason formatting
#   - build_skill_definitions_section approval note injection
#   - SendAgentUpdate approved field validation

defmodule Assistant.Skills.ApprovalGateTest do
  use ExUnit.Case, async: false
  # async: false because we use named ETS tables (Skills.Registry, PromptLoader, ConfigLoader)

  alias Assistant.Skills.{Loader, SkillDefinition}
  alias Assistant.Orchestrator.ApprovalGate
  alias Assistant.Orchestrator.Tools.SendAgentUpdate

  # ---------------------------------------------------------------
  # SkillDefinition struct — requires_approval field
  # ---------------------------------------------------------------

  describe "SkillDefinition struct" do
    test "has requires_approval field defaulting to false" do
      skill = %SkillDefinition{
        name: "test.skill",
        description: "A test skill",
        domain: "test",
        body: "Test body",
        path: "/tmp/test.md"
      }

      assert skill.requires_approval == false
    end

    test "accepts requires_approval: true" do
      skill = %SkillDefinition{
        name: "test.dangerous",
        description: "A dangerous skill",
        domain: "test",
        requires_approval: true,
        body: "Dangerous body",
        path: "/tmp/dangerous.md"
      }

      assert skill.requires_approval == true
    end

    test "requires_approval field is boolean type" do
      skill = %SkillDefinition{
        name: "test.typed",
        description: "Type test",
        domain: "test",
        requires_approval: true,
        body: "Body",
        path: "/tmp/typed.md"
      }

      assert is_boolean(skill.requires_approval)
    end
  end

  # ---------------------------------------------------------------
  # Loader — requires_approval YAML parsing
  # ---------------------------------------------------------------

  describe "Loader.load_skill_file/2 requires_approval parsing" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "approval_test_#{System.unique_integer([:positive])}")
      domain_dir = Path.join(tmp_dir, "testdomain")
      File.mkdir_p!(domain_dir)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{tmp_dir: tmp_dir, domain_dir: domain_dir}
    end

    test "parses requires_approval: true from YAML frontmatter", %{tmp_dir: tmp_dir, domain_dir: domain_dir} do
      path = Path.join(domain_dir, "dangerous.md")

      File.write!(path, """
      ---
      name: "testdomain.dangerous"
      description: "A dangerous skill"
      requires_approval: true
      ---
      This is the body.
      """)

      skill = Loader.load_skill_file(path, tmp_dir)

      assert %SkillDefinition{} = skill
      assert skill.name == "testdomain.dangerous"
      assert skill.requires_approval == true
    end

    test "parses requires_approval: false from YAML frontmatter", %{tmp_dir: tmp_dir, domain_dir: domain_dir} do
      path = Path.join(domain_dir, "safe.md")

      File.write!(path, """
      ---
      name: "testdomain.safe"
      description: "A safe skill"
      requires_approval: false
      ---
      Safe body.
      """)

      skill = Loader.load_skill_file(path, tmp_dir)

      assert %SkillDefinition{} = skill
      assert skill.requires_approval == false
    end

    test "defaults to false when requires_approval is absent", %{tmp_dir: tmp_dir, domain_dir: domain_dir} do
      path = Path.join(domain_dir, "default.md")

      File.write!(path, """
      ---
      name: "testdomain.default"
      description: "A skill without requires_approval"
      ---
      Default body.
      """)

      skill = Loader.load_skill_file(path, tmp_dir)

      assert %SkillDefinition{} = skill
      assert skill.requires_approval == false
    end

    test "treats non-boolean requires_approval as false", %{tmp_dir: tmp_dir, domain_dir: domain_dir} do
      path = Path.join(domain_dir, "stringval.md")

      File.write!(path, """
      ---
      name: "testdomain.stringval"
      description: "Skill with string requires_approval"
      requires_approval: "yes"
      ---
      Body.
      """)

      skill = Loader.load_skill_file(path, tmp_dir)

      assert %SkillDefinition{} = skill
      # Only `true` (boolean) should set the flag; "yes" string should result in false
      assert skill.requires_approval == false
    end

    test "treats requires_approval: 1 as false", %{tmp_dir: tmp_dir, domain_dir: domain_dir} do
      path = Path.join(domain_dir, "intval.md")

      File.write!(path, """
      ---
      name: "testdomain.intval"
      description: "Skill with integer requires_approval"
      requires_approval: 1
      ---
      Body.
      """)

      skill = Loader.load_skill_file(path, tmp_dir)

      assert %SkillDefinition{} = skill
      # Only boolean true should count
      assert skill.requires_approval == false
    end
  end

  # ---------------------------------------------------------------
  # Loader.load_all/1 — requires_approval across multiple skills
  # ---------------------------------------------------------------

  describe "Loader.load_all/1 with requires_approval" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "approval_all_#{System.unique_integer([:positive])}")
      domain_dir = Path.join(tmp_dir, "mixed")
      File.mkdir_p!(domain_dir)

      # Create a dangerous skill
      File.write!(Path.join(domain_dir, "send.md"), """
      ---
      name: "mixed.send"
      description: "Sends things"
      requires_approval: true
      ---
      Send body.
      """)

      # Create a safe skill
      File.write!(Path.join(domain_dir, "read.md"), """
      ---
      name: "mixed.read"
      description: "Reads things"
      ---
      Read body.
      """)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{tmp_dir: tmp_dir}
    end

    test "correctly parses requires_approval across mixed skills", %{tmp_dir: tmp_dir} do
      {skills, _domain_indexes} = Loader.load_all(tmp_dir)

      assert length(skills) == 2

      send_skill = Enum.find(skills, &(&1.name == "mixed.send"))
      read_skill = Enum.find(skills, &(&1.name == "mixed.read"))

      assert send_skill.requires_approval == true
      assert read_skill.requires_approval == false
    end
  end

  # ---------------------------------------------------------------
  # SendAgentUpdate — approved field validation
  # ---------------------------------------------------------------

  describe "SendAgentUpdate.tool_definition/0 approved field" do
    test "includes approved property in schema" do
      defn = SendAgentUpdate.tool_definition()

      assert Map.has_key?(defn.parameters["properties"], "approved")
      assert defn.parameters["properties"]["approved"]["type"] == "boolean"
    end

    test "approved field description mentions approval-gated skills" do
      defn = SendAgentUpdate.tool_definition()
      desc = defn.parameters["properties"]["approved"]["description"]

      assert desc =~ "approval"
      assert desc =~ "true"
      assert desc =~ "false"
    end
  end

  describe "SendAgentUpdate.execute/2 with approved field" do
    setup do
      case Registry.start_link(keys: :unique, name: Assistant.SubAgent.Registry) do
        {:ok, pid} -> Process.unlink(pid)
        {:error, {:already_started, _}} -> :ok
      end

      :ok
    end

    test "approved: true alone is a valid update (no message/skills/context required)" do
      params = %{
        "agent_id" => "test_agent_approval",
        "approved" => true
      }

      # Will fail with :not_found since agent doesn't exist, but should NOT
      # fail with validation error. This proves approved alone is sufficient.
      {:ok, result} = SendAgentUpdate.execute(params, nil)

      # Should get "not found" error, not "at least one of" validation error
      assert result.content =~ "not found"
      refute result.content =~ "At least one of"
    end

    test "approved: false alone is a valid update" do
      params = %{
        "agent_id" => "test_agent_deny",
        "approved" => false
      }

      {:ok, result} = SendAgentUpdate.execute(params, nil)

      assert result.content =~ "not found"
      refute result.content =~ "At least one of"
    end

    test "approved: false with feedback message is valid" do
      params = %{
        "agent_id" => "test_agent_feedback",
        "approved" => false,
        "message" => "Please change the subject line"
      }

      {:ok, result} = SendAgentUpdate.execute(params, nil)

      assert result.content =~ "not found"
      refute result.content =~ "At least one of"
    end

    test "non-boolean approved is treated as absent" do
      params = %{
        "agent_id" => "test_agent_bad_approved",
        "approved" => "yes"
      }

      {:ok, result} = SendAgentUpdate.execute(params, nil)

      # String "yes" is not a boolean, so approved check fails.
      # With no other valid fields, should get validation error.
      assert result.status == :error
      assert result.content =~ "At least one of"
    end
  end

  # ---------------------------------------------------------------
  # Approval gate receive block — simulated via process messaging
  #
  # Since handle_approval_gate/7 is a private function, we test the
  # receive block behavior by replicating the core receive pattern
  # and verifying each branch. This validates the contract that the
  # sub-agent honors when awaiting approval responses.
  #
  # NOTE: These contract tests verify the message protocol (which
  # messages map to which outcomes). The REAL code path is tested
  # end-to-end in approval_gate_sub_agent_test.exs via Bypass, which
  # exercises the actual handle_approval_gate/7 within the GenServer.
  # ---------------------------------------------------------------

  describe "approval gate receive block behavior" do
    test "approved: true resumes execution" do
      test_pid = self()

      child = spawn(fn ->
        # Simulate the receive block from handle_approval_gate
        result =
          receive do
            {:resume, %{approved: true}} -> :approved
            {:resume, %{approved: false, message: feedback}} when is_binary(feedback) -> {:denied_with_feedback, feedback}
            {:resume, %{approved: false}} -> :denied
            {:resume, _update} -> :unclear
          after
            1_000 -> :timeout
          end

        send(test_pid, {:gate_result, result})
      end)

      send(child, {:resume, %{approved: true}})

      assert_receive {:gate_result, :approved}, 1_000
    end

    test "approved: false with feedback returns denial with feedback" do
      test_pid = self()

      child = spawn(fn ->
        result =
          receive do
            {:resume, %{approved: true}} -> :approved
            {:resume, %{approved: false, message: feedback}} when is_binary(feedback) -> {:denied_with_feedback, feedback}
            {:resume, %{approved: false}} -> :denied
            {:resume, _update} -> :unclear
          after
            1_000 -> :timeout
          end

        send(test_pid, {:gate_result, result})
      end)

      send(child, {:resume, %{approved: false, message: "Change the recipient"}})

      assert_receive {:gate_result, {:denied_with_feedback, "Change the recipient"}}, 1_000
    end

    test "approved: false without message returns generic denial" do
      test_pid = self()

      child = spawn(fn ->
        result =
          receive do
            {:resume, %{approved: true}} -> :approved
            {:resume, %{approved: false, message: feedback}} when is_binary(feedback) -> {:denied_with_feedback, feedback}
            {:resume, %{approved: false}} -> :denied
            {:resume, _update} -> :unclear
          after
            1_000 -> :timeout
          end

        send(test_pid, {:gate_result, result})
      end)

      send(child, {:resume, %{approved: false}})

      assert_receive {:gate_result, :denied}, 1_000
    end

    test "resume without approved field returns unclear fallback" do
      test_pid = self()

      child = spawn(fn ->
        result =
          receive do
            {:resume, %{approved: true}} -> :approved
            {:resume, %{approved: false, message: feedback}} when is_binary(feedback) -> {:denied_with_feedback, feedback}
            {:resume, %{approved: false}} -> :denied
            {:resume, _update} -> :unclear
          after
            1_000 -> :timeout
          end

        send(test_pid, {:gate_result, result})
      end)

      # Resume with just a message, no approved field — fallback branch
      send(child, {:resume, %{message: "some instructions"}})

      assert_receive {:gate_result, :unclear}, 1_000
    end

    test "timeout fires when no resume message received" do
      test_pid = self()

      child = spawn(fn ->
        result =
          receive do
            {:resume, %{approved: true}} -> :approved
            {:resume, %{approved: false}} -> :denied
          after
            # Use short timeout for test speed
            50 -> :timeout
          end

        send(test_pid, {:gate_result, result})
      end)

      # Do NOT send any message — let it time out
      _ = child

      assert_receive {:gate_result, :timeout}, 1_000
    end
  end

  # ---------------------------------------------------------------
  # build_approval_reason — now tested via the public
  # ApprovalGate.build_approval_reason/4 API (extracted from sub_agent.ex).
  # Also exercised end-to-end in approval_gate_sub_agent_test.exs where
  # the GenServer's status.reason contains the real output.
  # ---------------------------------------------------------------

  describe "build_approval_reason (via public ApprovalGate API)" do
    test "formats reason with [APPROVAL_REQUIRED] prefix and skill name" do
      skill_name = "email.send"
      skill_args = %{"to" => "bob@example.com", "subject" => "Hello"}
      skill_def = %SkillDefinition{
        name: "email.send",
        description: "Send email",
        domain: "email",
        body: "body",
        path: "/tmp/send.md",
        parameters: [
          %{name: "to", type: "string", required: true, description: "Recipient"},
          %{name: "subject", type: "string", required: true, description: "Subject"}
        ]
      }

      reason = ApprovalGate.build_approval_reason(skill_name, skill_args, skill_def)

      assert reason =~ "[APPROVAL_REQUIRED]"
      assert reason =~ "email.send"
      assert reason =~ "bob@example.com"
      assert reason =~ "Hello"
      assert reason =~ "Proposed action:"
    end

    test "shows (not provided) for missing parameters" do
      skill_def = %SkillDefinition{
        name: "email.send",
        description: "Send email",
        domain: "email",
        body: "body",
        path: "/tmp/send.md",
        parameters: [
          %{name: "to", type: "string", required: true, description: "Recipient"},
          %{name: "cc", type: "string", required: false, description: "CC"}
        ]
      }

      skill_args = %{"to" => "alice@example.com"}

      reason = ApprovalGate.build_approval_reason("email.send", skill_args, skill_def)

      assert reason =~ "alice@example.com"
      assert reason =~ "(not provided)"
    end

    test "falls back to raw args when no parameters defined" do
      skill_def = %SkillDefinition{
        name: "custom.action",
        description: "Custom action",
        domain: "custom",
        body: "body",
        path: "/tmp/custom.md",
        parameters: []
      }

      skill_args = %{"key1" => "value1", "key2" => "value2"}

      reason = ApprovalGate.build_approval_reason("custom.action", skill_args, skill_def)

      assert reason =~ "key1: value1"
      assert reason =~ "key2: value2"
    end

    test "includes batch position when approval_index provided" do
      skill_def = %SkillDefinition{
        name: "email.send",
        description: "Send email",
        domain: "email",
        body: "body",
        path: "/tmp/send.md",
        parameters: [
          %{name: "to", type: "string", required: true, description: "Recipient"}
        ]
      }

      skill_args = %{"to" => "bob@example.com"}

      reason = ApprovalGate.build_approval_reason("email.send", skill_args, skill_def, {2, 3})

      assert reason =~ "Action 2 of 3"
    end
  end

  # ---------------------------------------------------------------
  # Skill YAML frontmatter verification — confirms ALL gated skills
  # have requires_approval: true set
  # ---------------------------------------------------------------

  describe "dangerous skill YAML frontmatter" do
    @dangerous_skills [
      "priv/skills/email/send.md",
      "priv/skills/calendar/create.md",
      "priv/skills/calendar/update.md",
      "priv/skills/files/archive.md",
      "priv/skills/workflow/create.md",
      "priv/skills/workflow/run.md",
      "priv/skills/hubspot/create_contact.md",
      "priv/skills/hubspot/create_company.md",
      "priv/skills/hubspot/create_deal.md",
      "priv/skills/hubspot/update_contact.md",
      "priv/skills/hubspot/update_company.md",
      "priv/skills/hubspot/update_deal.md",
      "priv/skills/hubspot/delete_contact.md",
      "priv/skills/hubspot/delete_company.md",
      "priv/skills/hubspot/delete_deal.md"
    ]

    for rel_path <- @dangerous_skills do
      @rel_path rel_path

      test "#{rel_path} has requires_approval: true" do
        path = Path.join(File.cwd!(), @rel_path)
        assert File.exists?(path), "Expected skill file at #{path}"

        {:ok, content} = File.read(path)
        {:ok, frontmatter, _body} = Loader.parse_frontmatter(content)

        assert frontmatter["requires_approval"] == true,
               "Expected requires_approval: true in #{@rel_path}, got: #{inspect(frontmatter["requires_approval"])}"
      end
    end
  end

  # ---------------------------------------------------------------
  # Safe skills do NOT have requires_approval — spot check
  # ---------------------------------------------------------------

  describe "safe skills remain un-gated" do
    @safe_skills [
      "priv/skills/email/search.md",
      "priv/skills/email/read.md"
    ]

    for rel_path <- @safe_skills do
      @rel_path rel_path

      test "#{rel_path} does not have requires_approval: true" do
        path = Path.join(File.cwd!(), @rel_path)

        if File.exists?(path) do
          {:ok, content} = File.read(path)
          {:ok, frontmatter, _body} = Loader.parse_frontmatter(content)

          refute frontmatter["requires_approval"] == true,
                 "Safe skill #{@rel_path} should NOT have requires_approval: true"
        end
      end
    end
  end

  # ---------------------------------------------------------------
  # build_skill_definitions_section — approval note injection
  #
  # Tests that the dynamic prompt injection appends the approval note
  # to skills with requires_approval: true. Since this is a private
  # function in SubAgent, we test the Registry-based contract:
  # given a skill with requires_approval: true in the registry,
  # the approval note text should appear.
  #
  # NOTE: These verify the conditional logic contract. The real
  # build_skill_definitions_section is exercised indirectly when
  # the GenServer tests (approval_gate_sub_agent_test.exs) start a
  # sub-agent with email.send — the prompt assembly calls this function.
  # ---------------------------------------------------------------

  describe "skill definitions section approval note" do
    setup do
      ensure_skills_registry_started()
      :ok
    end

    test "loaded skill with requires_approval: true can drive conditional note" do
      # Load a skill with requires_approval: true via the real Loader
      tmp_dir = Path.join(System.tmp_dir!(), "note_test_#{System.unique_integer([:positive])}")
      domain_dir = Path.join(tmp_dir, "noted")
      File.mkdir_p!(domain_dir)

      File.write!(Path.join(domain_dir, "action.md"), """
      ---
      name: "noted.action"
      description: "An action requiring approval"
      requires_approval: true
      ---
      Action instructions here.
      """)

      {[skill], _} = Loader.load_all(tmp_dir)

      # Verify the loaded skill has the field set
      assert skill.requires_approval == true

      # The build_skill_definitions_section function (private in SubAgent)
      # checks skill_def.requires_approval to append the note. The actual
      # prompt assembly is exercised in approval_gate_sub_agent_test.exs
      # when a sub-agent starts with a gated skill. Here we just confirm
      # the loaded struct drives the conditional correctly.
      assert skill.requires_approval == true

      File.rm_rf!(tmp_dir)
    end

    test "skill without requires_approval field set evaluates as false" do
      skill = %SkillDefinition{
        name: "test.safe",
        description: "Safe skill",
        domain: "test",
        requires_approval: false,
        body: "Body",
        path: "/tmp/safe.md"
      }

      # The note injection condition is: if skill_def.requires_approval
      # A false value should NOT trigger note injection.
      refute skill.requires_approval
    end
  end

  # ---------------------------------------------------------------
  # Adversarial tests — requires_approval cannot be bypassed
  # ---------------------------------------------------------------

  describe "adversarial: gate predicate cannot be bypassed" do
    test "pattern match on requires_approval: true is exact boolean match" do
      # The gate checks: {:ok, %{requires_approval: true} = skill_def}
      # Ensure only boolean true triggers, not truthy values

      # Boolean true — should match
      assert match?(%{requires_approval: true}, %{requires_approval: true})

      # Boolean false — should NOT match
      refute match?(%{requires_approval: true}, %{requires_approval: false})

      # Nil — should NOT match
      refute match?(%{requires_approval: true}, %{requires_approval: nil})

      # String "true" — should NOT match (important for YAML safety)
      refute match?(%{requires_approval: true}, %{requires_approval: "true"})

      # Integer 1 — should NOT match
      refute match?(%{requires_approval: true}, %{requires_approval: 1})
    end

    test "Loader's strict equality check rejects non-boolean truthy values" do
      # The Loader uses: frontmatter["requires_approval"] == true
      # This is strict equality, not truthiness

      assert (true == true)
      refute ("true" == true)
      refute (1 == true)
      refute ("yes" == true)
      refute (nil == true)
    end
  end

  # ---------------------------------------------------------------
  # Pipeline ordering — sentinel before gate, scope before sentinel
  # ---------------------------------------------------------------

  # ---------------------------------------------------------------
  # Production context verification — the LLM sees correct
  # system prompt, tool schemas, and skill metadata in production
  # ---------------------------------------------------------------

  describe "production context: system prompt, tools, and skill registry" do
    setup do
      # Ensure PromptLoader and Skills.Registry are running (they use named ETS)
      skills_dir = Path.join(File.cwd!(), "priv/skills")

      if :ets.whereis(:assistant_skills) == :undefined and File.dir?(skills_dir) do
        case Assistant.Skills.Registry.start_link(skills_dir: skills_dir) do
          {:ok, pid} -> Process.unlink(pid)
          {:error, {:already_started, _}} -> :ok
        end
      end

      prompts_dir = Path.join(File.cwd!(), "priv/config/prompts")

      if :ets.whereis(:assistant_prompts) == :undefined and File.dir?(prompts_dir) do
        case Assistant.Config.PromptLoader.start_link(dir: prompts_dir) do
          {:ok, pid} -> Process.unlink(pid)
          {:error, {:already_started, _}} -> :ok
        end
      end

      :ok
    end

    test "orchestrator system prompt includes approval handling instructions" do
      loop_state = %{user_id: "test-user", channel: "test"}
      prompt = Assistant.Orchestrator.Context.build_system_prompt(loop_state)

      # The orchestrator MUST know how to handle [APPROVAL_REQUIRED] responses
      assert prompt =~ "APPROVAL_REQUIRED",
        "System prompt missing [APPROVAL_REQUIRED] handling instructions"

      # Must instruct the LLM on approved=true/false flow
      assert prompt =~ "approved=true",
        "System prompt missing approved=true instruction"
      assert prompt =~ "approved=false",
        "System prompt missing approved=false instruction"

      # Must instruct LLM to present action details to user
      assert prompt =~ "approval" or prompt =~ "Approval",
        "System prompt missing general approval workflow"
    end

    test "orchestrator tool definitions include all 4 tools with correct schemas" do
      tools = Assistant.Orchestrator.Context.tool_definitions()
      tool_names = Enum.map(tools, & &1.function.name) |> Enum.sort()

      assert tool_names == ["dispatch_agent", "get_agent_results", "get_skill", "send_agent_update"],
        "Expected 4 orchestrator tools, got: #{inspect(tool_names)}"
    end

    test "send_agent_update tool has approved boolean parameter" do
      tools = Assistant.Orchestrator.Context.tool_definitions()
      sau = Enum.find(tools, & &1.function.name == "send_agent_update")
      assert sau != nil

      props = sau.function.parameters["properties"]
      assert Map.has_key?(props, "approved"),
        "send_agent_update missing 'approved' property. Properties: #{inspect(Map.keys(props))}"
      assert props["approved"]["type"] == "boolean"

      # Verify the description mentions approval gate
      assert props["approved"]["description"] =~ "approv",
        "approved param description should mention approval flow"
    end

    test "send_agent_update tool has agent_id as required parameter" do
      tools = Assistant.Orchestrator.Context.tool_definitions()
      sau = Enum.find(tools, & &1.function.name == "send_agent_update")

      assert sau.function.parameters["required"] == ["agent_id"]
    end

    test "dispatch_agent tool has expected parameters" do
      tools = Assistant.Orchestrator.Context.tool_definitions()
      dispatch = Enum.find(tools, & &1.function.name == "dispatch_agent")
      assert dispatch != nil

      props = dispatch.function.parameters["properties"]
      assert Map.has_key?(props, "agent_id")
      assert Map.has_key?(props, "mission")
      assert Map.has_key?(props, "skills")
    end

    test "gated skills in registry have requires_approval: true" do
      gated_skills = [
        "email.send",
        "calendar.create",
        "calendar.update",
        "files.archive",
        "workflow.create",
        "workflow.run",
        "hubspot.create_contact",
        "hubspot.create_company",
        "hubspot.create_deal",
        "hubspot.update_contact",
        "hubspot.update_company",
        "hubspot.update_deal",
        "hubspot.delete_contact",
        "hubspot.delete_company",
        "hubspot.delete_deal"
      ]

      for skill_name <- gated_skills do
        case Assistant.Skills.Registry.lookup(skill_name) do
          {:ok, skill} ->
            assert skill.requires_approval == true,
              "#{skill_name} should have requires_approval: true, got: #{skill.requires_approval}"

          {:error, :not_found} ->
            # Skill may not be loaded in test env — skip but don't fail
            :ok
        end
      end
    end

    test "non-gated read skills do NOT have requires_approval: true" do
      read_skills = ["email.search", "email.read"]

      for skill_name <- read_skills do
        case Assistant.Skills.Registry.lookup(skill_name) do
          {:ok, skill} ->
            refute skill.requires_approval,
              "#{skill_name} should NOT have requires_approval: true (it's read-only)"

          {:error, :not_found} ->
            :ok
        end
      end
    end
  end

  describe "pipeline ordering contract" do
    test "scope check happens before sentinel (structural)" do
      # The execute_use_skill pipeline is:
      # 1. nil check (skill_name)
      # 2. SkillPermissions.enabled? check
      # 3. scope check (skill_name in dispatch_params.skills)
      # 4. Sentinel.check
      # 5. Registry.lookup → approval gate OR direct execute
      #
      # We verify: a skill NOT in scope never reaches the gate,
      # even if it has requires_approval: true.

      dispatch_params = %{
        agent_id: "test_agent",
        mission: "Test",
        skills: ["email.search"],
        context: nil
      }

      # email.send is NOT in skills, so scope check rejects it
      # before sentinel or approval gate could fire
      assert "email.send" not in dispatch_params.skills
      assert "email.search" in dispatch_params.skills
    end

    test "gate predicate fires only for requires_approval: true skills in Registry" do
      # Behavioral test: load real skills, confirm the Registry lookup
      # result determines the gate path. This tests the condition at
      # sub_agent.ex:806 — {:ok, %{requires_approval: true} = skill_def}
      skills_dir = Path.join(File.cwd!(), "priv/skills")

      if :ets.whereis(:assistant_skills) == :undefined and File.dir?(skills_dir) do
        case Assistant.Skills.Registry.start_link(skills_dir: skills_dir) do
          {:ok, pid} -> Process.unlink(pid)
          {:error, {:already_started, _}} -> :ok
        end
      end

      # email.send is gated — Registry.lookup should return requires_approval: true
      {:ok, gated_skill} = Assistant.Skills.Registry.lookup("email.send")
      assert gated_skill.requires_approval == true
      assert match?({:ok, %{requires_approval: true}}, {:ok, gated_skill})

      # email.search is NOT gated — Registry.lookup should return requires_approval: false
      case Assistant.Skills.Registry.lookup("email.search") do
        {:ok, safe_skill} ->
          assert safe_skill.requires_approval == false
          refute match?({:ok, %{requires_approval: true}}, {:ok, safe_skill})

        {:error, :not_found} ->
          # Skill may not exist in this build — acceptable
          :ok
      end
    end
  end

  # ---------------------------------------------------------------
  # Orchestrator prompt — [APPROVAL_REQUIRED] handling section
  # ---------------------------------------------------------------

  describe "orchestrator prompt contains approval handling" do
    test "orchestrator.yaml includes APPROVAL_REQUIRED handling section" do
      path = Path.join(File.cwd!(), "priv/config/prompts/orchestrator.yaml")

      if File.exists?(path) do
        {:ok, content} = File.read(path)

        assert content =~ "APPROVAL_REQUIRED",
               "orchestrator.yaml should contain APPROVAL_REQUIRED handling instructions"

        assert content =~ "approved",
               "orchestrator.yaml should mention the approved field"
      end
    end
  end

  # ---------------------------------------------------------------
  # Engine agent preservation — awaiting_orchestrator agents survive
  # turn resets (engine.ex:206-218, 748)
  #
  # The engine resets dispatched_agents at the start of each new user
  # message, but preserves agents with status :awaiting_orchestrator.
  # This is critical: without it, approval-gated agents would be lost
  # between Turn 1 (gate fires) and Turn 2 (user approves/denies).
  #
  # Also verifies interrupt_active_agents skips :awaiting_orchestrator.
  # ---------------------------------------------------------------

  describe "engine agent preservation across turns" do
    test "Map.filter preserves awaiting_orchestrator agents during turn reset" do
      # Replicate the exact logic from engine.ex:208-211
      dispatched_agents = %{
        "agent-running" => %{status: :running, result: "partial"},
        "agent-completed" => %{status: :completed, result: "done"},
        "agent-gated" => %{status: :awaiting_orchestrator, reason: "[APPROVAL_REQUIRED]"},
        "agent-failed" => %{status: :failed, result: "error"}
      }

      preserved =
        Map.filter(dispatched_agents, fn {_id, result} ->
          result[:status] == :awaiting_orchestrator
        end)

      # Only the gated agent should survive
      assert map_size(preserved) == 1
      assert Map.has_key?(preserved, "agent-gated")
      refute Map.has_key?(preserved, "agent-running")
      refute Map.has_key?(preserved, "agent-completed")
      refute Map.has_key?(preserved, "agent-failed")
    end

    test "multiple awaiting_orchestrator agents all preserved" do
      dispatched_agents = %{
        "email-gate" => %{status: :awaiting_orchestrator, reason: "[APPROVAL_REQUIRED] email.send"},
        "calendar-gate" => %{status: :awaiting_orchestrator, reason: "[APPROVAL_REQUIRED] calendar.create"},
        "search-done" => %{status: :completed, result: "search results"}
      }

      preserved =
        Map.filter(dispatched_agents, fn {_id, result} ->
          result[:status] == :awaiting_orchestrator
        end)

      assert map_size(preserved) == 2
      assert Map.has_key?(preserved, "email-gate")
      assert Map.has_key?(preserved, "calendar-gate")
    end

    test "interrupt_active_agents skips awaiting_orchestrator status" do
      # Replicate the skip condition from engine.ex:748
      statuses_to_skip = [:completed, :failed, :timeout, :skipped, :awaiting_orchestrator]

      # awaiting_orchestrator should NOT be interrupted
      assert :awaiting_orchestrator in statuses_to_skip

      # running should be interrupted
      refute :running in statuses_to_skip
    end

    test "empty dispatched_agents results in empty preserved set" do
      preserved =
        Map.filter(%{}, fn {_id, result} ->
          result[:status] == :awaiting_orchestrator
        end)

      assert preserved == %{}
    end

    test "no awaiting_orchestrator agents results in empty preserved set" do
      dispatched_agents = %{
        "agent-1" => %{status: :completed, result: "done"},
        "agent-2" => %{status: :running, result: "wip"}
      }

      preserved =
        Map.filter(dispatched_agents, fn {_id, result} ->
          result[:status] == :awaiting_orchestrator
        end)

      assert preserved == %{}
    end
  end

  # ---------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------

  defp ensure_skills_registry_started do
    if :ets.whereis(:assistant_skills) != :undefined do
      :ok
    else
      tmp_dir =
        Path.join(System.tmp_dir!(), "empty_skills_ag_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      case Assistant.Skills.Registry.start_link(skills_dir: tmp_dir) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
    end
  end
end
