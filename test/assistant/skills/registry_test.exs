# test/assistant/skills/registry_test.exs
#
# Tests for the ETS-backed skill registry. Starts a dedicated Registry
# per test with a temp skills directory to avoid interfering with the
# app-level registry.

defmodule Assistant.Skills.RegistryTest do
  use ExUnit.Case, async: false
  # async: false because Registry uses a named ETS table (:assistant_skills)

  alias Assistant.Skills.{Registry, SkillDefinition, DomainIndex}

  setup do
    # Stop the app-level Registry if running
    if Process.whereis(Registry) do
      GenServer.stop(Registry, :normal, 1_000)
      Process.sleep(50)
    end

    # Clean up the named ETS table if it persists
    if :ets.whereis(:assistant_skills) != :undefined do
      try do
        :ets.delete(:assistant_skills)
      rescue
        ArgumentError -> :ok
      end
    end

    # Create a temp skills directory with test skill files
    tmp_dir = Path.join(System.tmp_dir!(), "skills_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp_dir, "email"))
    File.mkdir_p!(Path.join(tmp_dir, "memory"))

    # Write test skill files
    File.write!(Path.join(tmp_dir, "email/send.md"), """
    ---
    name: "email.send"
    description: "Send an email to a recipient"
    tags:
      - email
      - communication
    ---

    # email.send

    Send an email message.

    ## Parameters

    | Parameter | Type | Required |
    |-----------|------|----------|
    | to | string | yes |
    | subject | string | yes |
    | body | string | yes |
    """)

    File.write!(Path.join(tmp_dir, "email/search.md"), """
    ---
    name: "email.search"
    description: "Search emails by query"
    tags:
      - email
      - search
    ---

    # email.search

    Search the user's email inbox.
    """)

    File.write!(Path.join(tmp_dir, "memory/save_memory.md"), """
    ---
    name: "memory.save_memory"
    description: "Save a memory entry"
    tags:
      - memory
      - write
    ---

    # memory.save_memory

    Save a piece of information to persistent memory.
    """)

    # Write a SKILL.md domain index
    File.write!(Path.join(tmp_dir, "email/SKILL.md"), """
    ---
    domain: "email"
    description: "Email management skills"
    ---

    # Email Domain

    Skills for sending and searching emails.
    """)

    on_exit(fn ->
      if Process.whereis(Registry) do
        GenServer.stop(Registry, :normal, 1_000)
        Process.sleep(20)
      end

      if :ets.whereis(:assistant_skills) != :undefined do
        try do
          :ets.delete(:assistant_skills)
        rescue
          ArgumentError -> :ok
        end
      end

      File.rm_rf!(tmp_dir)
    end)

    %{skills_dir: tmp_dir}
  end

  # ---------------------------------------------------------------
  # Startup and loading
  # ---------------------------------------------------------------

  describe "start_link/1" do
    test "loads skills from directory", %{skills_dir: dir} do
      {:ok, pid} = Registry.start_link(skills_dir: dir)
      assert Process.alive?(pid)

      # Should have loaded 3 skills
      all = Registry.list_all()
      assert length(all) == 3

      GenServer.stop(pid)
    end

    test "loads domain indexes", %{skills_dir: dir} do
      {:ok, pid} = Registry.start_link(skills_dir: dir)

      indexes = Registry.list_domain_indexes()
      assert length(indexes) >= 1

      email_index = Enum.find(indexes, &(&1.domain == "email"))
      assert email_index != nil
      assert email_index.description == "Email management skills"

      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------
  # lookup/1
  # ---------------------------------------------------------------

  describe "lookup/1" do
    setup %{skills_dir: dir} do
      {:ok, pid} = Registry.start_link(skills_dir: dir)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      :ok
    end

    test "finds skill by name" do
      assert {:ok, %SkillDefinition{} = skill} = Registry.lookup("email.send")
      assert skill.name == "email.send"
      assert skill.description == "Send an email to a recipient"
      assert skill.domain == "email"
    end

    test "returns {:error, :not_found} for unknown skill" do
      assert {:error, :not_found} = Registry.lookup("nonexistent.skill")
    end
  end

  # ---------------------------------------------------------------
  # skill_exists?/1
  # ---------------------------------------------------------------

  describe "skill_exists?/1" do
    setup %{skills_dir: dir} do
      {:ok, pid} = Registry.start_link(skills_dir: dir)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      :ok
    end

    test "returns true for existing skill" do
      assert Registry.skill_exists?("email.send")
    end

    test "returns false for nonexistent skill" do
      refute Registry.skill_exists?("nonexistent.skill")
    end
  end

  # ---------------------------------------------------------------
  # list_by_domain/1
  # ---------------------------------------------------------------

  describe "list_by_domain/1" do
    setup %{skills_dir: dir} do
      {:ok, pid} = Registry.start_link(skills_dir: dir)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      :ok
    end

    test "returns skills in specified domain" do
      email_skills = Registry.list_by_domain("email")
      assert length(email_skills) == 2

      names = Enum.map(email_skills, & &1.name)
      assert "email.send" in names
      assert "email.search" in names
    end

    test "returns skills for memory domain" do
      memory_skills = Registry.list_by_domain("memory")
      assert length(memory_skills) == 1
      assert hd(memory_skills).name == "memory.save_memory"
    end

    test "returns empty list for unknown domain" do
      assert Registry.list_by_domain("nonexistent") == []
    end
  end

  # ---------------------------------------------------------------
  # list_all/0
  # ---------------------------------------------------------------

  describe "list_all/0" do
    setup %{skills_dir: dir} do
      {:ok, pid} = Registry.start_link(skills_dir: dir)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      :ok
    end

    test "returns all registered skills" do
      all = Registry.list_all()
      assert length(all) == 3

      names = Enum.map(all, & &1.name) |> Enum.sort()
      assert names == ["email.search", "email.send", "memory.save_memory"]
    end
  end

  # ---------------------------------------------------------------
  # search/1
  # ---------------------------------------------------------------

  describe "search/1" do
    setup %{skills_dir: dir} do
      {:ok, pid} = Registry.start_link(skills_dir: dir)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      :ok
    end

    test "searches by name substring" do
      results = Registry.search("send")
      assert length(results) == 1
      assert hd(results).name == "email.send"
    end

    test "searches by description" do
      results = Registry.search("Search emails")
      assert length(results) == 1
      assert hd(results).name == "email.search"
    end

    test "searches by tag" do
      results = Registry.search("communication")
      assert length(results) == 1
      assert hd(results).name == "email.send"
    end

    test "case-insensitive search" do
      results = Registry.search("EMAIL")
      assert length(results) >= 2
    end

    test "returns empty for no match" do
      results = Registry.search("zzzzz_no_match")
      assert results == []
    end
  end

  # ---------------------------------------------------------------
  # get_domain_index/1
  # ---------------------------------------------------------------

  describe "get_domain_index/1" do
    setup %{skills_dir: dir} do
      {:ok, pid} = Registry.start_link(skills_dir: dir)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      :ok
    end

    test "returns domain index for known domain" do
      assert {:ok, %DomainIndex{} = index} = Registry.get_domain_index("email")
      assert index.domain == "email"
      assert index.description == "Email management skills"
    end

    test "returns {:error, :not_found} for unknown domain" do
      assert {:error, :not_found} = Registry.get_domain_index("nonexistent")
    end
  end

  # ---------------------------------------------------------------
  # Empty skills directory
  # ---------------------------------------------------------------

  describe "empty skills directory" do
    test "starts with empty dir" do
      empty_dir = Path.join(System.tmp_dir!(), "empty_skills_#{System.unique_integer([:positive])}")
      File.mkdir_p!(empty_dir)

      {:ok, pid} = Registry.start_link(skills_dir: empty_dir)
      assert Registry.list_all() == []
      assert Registry.list_domain_indexes() == []

      GenServer.stop(pid)
      File.rm_rf!(empty_dir)
    end
  end
end
