# test/assistant/orchestrator/tools/get_skill_test.exs
#
# Tests for the GetSkill meta-tool (progressive-disclosure skill discovery).
# Uses Skills.Registry ETS backend with test skill data.

defmodule Assistant.Orchestrator.Tools.GetSkillTest do
  use ExUnit.Case, async: false
  # async: false because we use named ETS tables (skills registry)

  alias Assistant.Orchestrator.Tools.GetSkill

  setup do
    ensure_skills_registry_started()
    :ok
  end

  # ---------------------------------------------------------------
  # tool_definition/0
  # ---------------------------------------------------------------

  describe "tool_definition/0" do
    test "returns a valid tool definition map" do
      defn = GetSkill.tool_definition()

      assert defn.name == "get_skill"
      assert is_binary(defn.description)
      assert is_map(defn.parameters)
      assert defn.parameters["type"] == "object"
      assert Map.has_key?(defn.parameters["properties"], "skill_or_domain")
      assert Map.has_key?(defn.parameters["properties"], "search")
    end
  end

  # ---------------------------------------------------------------
  # execute/2 — no arguments (list all domains)
  # ---------------------------------------------------------------

  describe "execute/2 with no arguments" do
    test "returns domain list when skills are registered" do
      {:ok, result} = GetSkill.execute(%{}, nil)

      assert result.status == :ok
      assert is_binary(result.content)
      assert result.metadata.level == :domains
    end

    test "returns 'no domains' when registry is empty" do
      # With our empty skills dir, there may be no domains
      {:ok, result} = GetSkill.execute(%{}, nil)
      assert result.status == :ok
    end
  end

  # ---------------------------------------------------------------
  # execute/2 — unknown domain
  # ---------------------------------------------------------------

  describe "execute/2 with unknown domain" do
    test "returns error for nonexistent domain" do
      {:ok, result} = GetSkill.execute(%{"skill_or_domain" => "nonexistent"}, nil)

      assert result.status == :error
      assert result.content =~ "Unknown domain"
      assert result.metadata.level == :domain_index
    end
  end

  # ---------------------------------------------------------------
  # execute/2 — unknown specific skill
  # ---------------------------------------------------------------

  describe "execute/2 with unknown skill" do
    test "returns error for nonexistent skill" do
      {:ok, result} = GetSkill.execute(%{"skill_or_domain" => "nonexistent.skill"}, nil)

      assert result.status == :error
      assert result.content =~ "Unknown skill"
      assert result.metadata.level == :skill
    end
  end

  # ---------------------------------------------------------------
  # execute/2 — domain.all for unknown domain
  # ---------------------------------------------------------------

  describe "execute/2 with domain.all" do
    test "returns error for nonexistent domain.all" do
      {:ok, result} = GetSkill.execute(%{"skill_or_domain" => "nonexistent.all"}, nil)

      assert result.status == :error
      assert result.content =~ "No skills found"
      assert result.metadata.level == :domain_all
    end
  end

  # ---------------------------------------------------------------
  # execute/2 — search
  # ---------------------------------------------------------------

  describe "execute/2 with search" do
    test "returns empty search results for unmatched query" do
      {:ok, result} = GetSkill.execute(%{"search" => "xyznonexistent"}, nil)

      assert result.status == :ok
      assert result.content =~ "No skills found matching"
      assert result.metadata.level == :search
      assert result.metadata.result_count == 0
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
        Path.join(System.tmp_dir!(), "empty_skills_gs_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      case Assistant.Skills.Registry.start_link(skills_dir: tmp_dir) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
    end
  end
end
