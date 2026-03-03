# test/assistant/orchestrator/tools/get_skill_progressive_test.exs
#
# Tests for GetSkill progressive disclosure with actual registered skills.
# The basic get_skill_test.exs uses an empty registry. This file verifies
# all four disclosure levels and search functionality against whatever
# skills are registered (real project skills or app-loaded skills).
#
# These tests validate the tool chain discovery flow: the orchestrator
# calls get_skill progressively to understand available capabilities
# before dispatching sub-agents.

defmodule Assistant.Orchestrator.Tools.GetSkillProgressiveTest do
  use ExUnit.Case, async: false
  # async: false because we use named ETS table (:assistant_skills)

  alias Assistant.Orchestrator.Tools.GetSkill
  alias Assistant.Skills.Registry

  setup do
    ensure_skills_registry_started()
    :ok
  end

  # ---------------------------------------------------------------
  # Level 0: List all domains
  # ---------------------------------------------------------------

  describe "execute/2 — level 0: list all domains" do
    test "lists registered domains with skill counts" do
      {:ok, result} = GetSkill.execute(%{}, nil)

      assert result.status == :ok
      assert result.metadata.level == :domains

      # If skills are registered, domain_count > 0 and content includes domain names
      if result.metadata.domain_count > 0 do
        assert result.content =~ "domains"
        assert result.content =~ "skills"
      end
    end

    test "returns domain_count metadata" do
      {:ok, result} = GetSkill.execute(%{}, nil)
      assert is_integer(result.metadata.domain_count)
      assert result.metadata.domain_count >= 0
    end

    test "email and calendar domains exist in the project" do
      {:ok, result} = GetSkill.execute(%{}, nil)

      # These domains exist in the real project
      assert result.content =~ "email"
      assert result.content =~ "calendar"
    end
  end

  # ---------------------------------------------------------------
  # Level 1: Domain index (SKILL.md)
  # ---------------------------------------------------------------

  describe "execute/2 — level 1: domain index" do
    test "returns SKILL.md body for known domain" do
      {:ok, result} = GetSkill.execute(%{"skill_or_domain" => "email"}, nil)

      assert result.status == :ok
      assert result.metadata.level == :domain_index
      assert result.metadata.domain == "email"
      # The body comes from the SKILL.md file — verify it has non-trivial content
      assert is_binary(result.content)
      assert String.length(result.content) > 50
    end

    test "returns error for unknown domain" do
      {:ok, result} = GetSkill.execute(%{"skill_or_domain" => "nonexistent_domain_xyz"}, nil)

      assert result.status == :error
      assert result.content =~ "Unknown domain"
      # Should list available domains
      assert result.content =~ "email"
    end

    test "returns calendar domain index" do
      {:ok, result} = GetSkill.execute(%{"skill_or_domain" => "calendar"}, nil)

      assert result.status == :ok
      assert result.metadata.level == :domain_index
      assert result.metadata.domain == "calendar"
    end
  end

  # ---------------------------------------------------------------
  # Level 2: Specific skill
  # ---------------------------------------------------------------

  describe "execute/2 — level 2: specific skill" do
    test "returns skill body for email.search" do
      {:ok, result} = GetSkill.execute(%{"skill_or_domain" => "email.search"}, nil)

      assert result.status == :ok
      assert result.metadata.level == :skill
      assert result.metadata.skill == "email.search"
      assert result.metadata.domain == "email"
      assert is_binary(result.content)
      assert String.length(result.content) > 20
    end

    test "returns skill body for email.send" do
      {:ok, result} = GetSkill.execute(%{"skill_or_domain" => "email.send"}, nil)

      assert result.status == :ok
      assert result.metadata.level == :skill
      assert result.metadata.skill == "email.send"
    end

    test "returns error with suggestions for unknown skill in known domain" do
      {:ok, result} = GetSkill.execute(%{"skill_or_domain" => "email.nonexistent"}, nil)

      assert result.status == :error
      assert result.content =~ "Unknown skill"
      # Should suggest available skills in the email domain
      assert result.content =~ "email."
    end

    test "returns error for skill in completely unknown domain" do
      {:ok, result} = GetSkill.execute(%{"skill_or_domain" => "xyzdomain.unknown"}, nil)

      assert result.status == :error
      assert result.content =~ "Unknown skill"
    end
  end

  # ---------------------------------------------------------------
  # Level 3: Domain.all
  # ---------------------------------------------------------------

  describe "execute/2 — level 3: domain.all" do
    test "returns all skills in email domain" do
      {:ok, result} = GetSkill.execute(%{"skill_or_domain" => "email.all"}, nil)

      assert result.status == :ok
      assert result.metadata.level == :domain_all
      assert result.metadata.domain == "email"
      assert result.metadata.skill_count >= 3

      # Should contain known email skills
      assert result.content =~ "email.search"
      assert result.content =~ "email.send"
    end

    test "returns error for unknown domain.all" do
      {:ok, result} = GetSkill.execute(%{"skill_or_domain" => "nonexistent_xyz.all"}, nil)

      assert result.status == :error
      assert result.content =~ "No skills found"
    end

    test "returns all skills in calendar domain" do
      {:ok, result} = GetSkill.execute(%{"skill_or_domain" => "calendar.all"}, nil)

      assert result.status == :ok
      assert result.metadata.level == :domain_all
      assert result.metadata.domain == "calendar"
      assert result.metadata.skill_count >= 1
    end
  end

  # ---------------------------------------------------------------
  # Search
  # ---------------------------------------------------------------

  describe "execute/2 — search" do
    test "finds skills by name substring" do
      {:ok, result} = GetSkill.execute(%{"search" => "search"}, nil)

      assert result.status == :ok
      assert result.metadata.level == :search
      assert result.metadata.result_count >= 1
      assert result.content =~ "email.search"
    end

    test "finds skills matching 'send'" do
      {:ok, result} = GetSkill.execute(%{"search" => "send"}, nil)

      assert result.status == :ok
      assert result.metadata.result_count >= 1
      assert result.content =~ "email.send"
    end

    test "returns empty for no matches" do
      {:ok, result} = GetSkill.execute(%{"search" => "xyznonexistent123abc"}, nil)

      assert result.status == :ok
      assert result.metadata.result_count == 0
      assert result.content =~ "No skills found matching"
    end

    test "search is case-insensitive" do
      {:ok, result1} = GetSkill.execute(%{"search" => "search"}, nil)
      {:ok, result2} = GetSkill.execute(%{"search" => "SEARCH"}, nil)

      assert result1.metadata.result_count == result2.metadata.result_count
    end
  end

  # ---------------------------------------------------------------
  # Tool definition with live registry
  # ---------------------------------------------------------------

  describe "tool_definition/0 with registered skills" do
    test "includes registered domains in description" do
      defn = GetSkill.tool_definition()

      desc = defn.parameters["properties"]["skill_or_domain"]["description"]
      assert desc =~ "email"
    end
  end

  # ---------------------------------------------------------------
  # Progressive disclosure chain simulation
  # ---------------------------------------------------------------

  describe "progressive disclosure chain" do
    test "simulates orchestrator discovery: domains → domain → skill" do
      # Step 1: What domains are available?
      {:ok, domains_result} = GetSkill.execute(%{}, nil)
      assert domains_result.metadata.level == :domains
      assert domains_result.metadata.domain_count > 0

      # Step 2: What skills does the email domain have?
      {:ok, domain_result} = GetSkill.execute(%{"skill_or_domain" => "email"}, nil)
      assert domain_result.metadata.level == :domain_index

      # Step 3: What does email.search do specifically?
      {:ok, skill_result} = GetSkill.execute(%{"skill_or_domain" => "email.search"}, nil)
      assert skill_result.metadata.level == :skill
      assert skill_result.metadata.skill == "email.search"
    end

    test "simulates search-driven discovery" do
      # Orchestrator searches for a capability
      {:ok, search_result} = GetSkill.execute(%{"search" => "send"}, nil)
      assert search_result.metadata.result_count >= 1

      # Then looks up the specific skill found
      {:ok, detail_result} = GetSkill.execute(%{"skill_or_domain" => "email.send"}, nil)
      assert detail_result.metadata.level == :skill
    end
  end

  # ---------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------

  defp ensure_skills_registry_started do
    # Use the app-started registry with real project skills,
    # or start with the real skills dir if not yet running.
    if :ets.whereis(:assistant_skills) != :undefined do
      :ok
    else
      skills_dir = Path.join(File.cwd!(), "priv/skills")

      if File.dir?(skills_dir) do
        case Registry.start_link(skills_dir: skills_dir) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end
      else
        # Fallback: create minimal test skills
        tmp_dir =
          Path.join(System.tmp_dir!(), "test_skills_prog_#{System.unique_integer([:positive])}")

        File.mkdir_p!(tmp_dir)

        case Registry.start_link(skills_dir: tmp_dir) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end
      end
    end
  end
end
