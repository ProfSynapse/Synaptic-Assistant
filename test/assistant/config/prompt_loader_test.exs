# test/assistant/config/prompt_loader_test.exs
#
# Tests for prompt template loading and EEx rendering.
# Uses a temp directory with test YAML files.

defmodule Assistant.Config.PromptLoaderTest do
  use ExUnit.Case, async: false
  # async: false because we use a named ETS table

  alias Assistant.Config.PromptLoader

  @test_prompt_yaml """
  system: |
    You are an AI assistant.
    Available domains: <%= @skill_domains %>
    User: <%= @user_id %>
    Date: <%= @current_date %>
  """

  @test_sections_yaml """
  system: |
    Base system prompt.

  sections:
    topic_extraction: |
      Extract topics from: <%= @text %>
    summary: |
      Summarize the following: <%= @content %>
  """

  setup do
    # Stop the app-level PromptLoader if running
    if Process.whereis(PromptLoader) do
      GenServer.stop(PromptLoader, :normal, 1_000)
      Process.sleep(50)
    end

    # Create temp directory with test YAML files
    tmp_dir = Path.join(System.tmp_dir!(), "prompts_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    File.write!(Path.join(tmp_dir, "orchestrator.yaml"), @test_prompt_yaml)
    File.write!(Path.join(tmp_dir, "memory.yaml"), @test_sections_yaml)

    on_exit(fn ->
      # Stop the named GenServer if still alive
      case Process.whereis(PromptLoader) do
        nil -> :ok
        pid -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
      end

      Process.sleep(10)
      File.rm_rf!(tmp_dir)

      if :ets.whereis(:assistant_prompts) != :undefined do
        try do
          :ets.delete(:assistant_prompts)
        rescue
          ArgumentError -> :ok
        end
      end
    end)

    %{prompts_dir: tmp_dir}
  end

  # ---------------------------------------------------------------
  # render/2
  # ---------------------------------------------------------------

  describe "render/2" do
    setup %{prompts_dir: dir} do
      {:ok, pid} = PromptLoader.start_link(dir: dir)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      :ok
    end

    test "renders template with variable bindings" do
      assigns = %{
        skill_domains: "email, tasks, calendar",
        user_id: "user_123",
        current_date: "2026-02-18"
      }

      assert {:ok, rendered} = PromptLoader.render(:orchestrator, assigns)
      assert rendered =~ "email, tasks, calendar"
      assert rendered =~ "user_123"
      assert rendered =~ "2026-02-18"
    end

    test "returns error for unknown prompt name" do
      assert {:error, :not_found} = PromptLoader.render(:nonexistent)
    end

    test "renders empty interpolations for missing variables" do
      # EEx renders missing assigns as empty strings (nil → "")
      # rather than raising an error
      assert {:ok, rendered} = PromptLoader.render(:orchestrator, %{})
      assert rendered =~ "You are an AI assistant."
      # Variables should be blank but the template still renders
      assert rendered =~ "Available domains:"
    end
  end

  # ---------------------------------------------------------------
  # render_section/3
  # ---------------------------------------------------------------

  describe "render_section/3" do
    setup %{prompts_dir: dir} do
      {:ok, pid} = PromptLoader.start_link(dir: dir)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      :ok
    end

    test "renders named section with variables" do
      assert {:ok, rendered} =
               PromptLoader.render_section(:memory, :topic_extraction, %{
                 text: "conversation about AI"
               })

      assert rendered =~ "conversation about AI"
    end

    test "renders different sections from same file" do
      assert {:ok, topic_result} =
               PromptLoader.render_section(:memory, :topic_extraction, %{text: "topic"})

      assert {:ok, summary_result} =
               PromptLoader.render_section(:memory, :summary, %{content: "stuff"})

      assert topic_result =~ "topic"
      assert summary_result =~ "stuff"
    end

    test "returns error for unknown section" do
      assert {:error, :not_found} =
               PromptLoader.render_section(:memory, :nonexistent_section, %{})
    end

    test "returns error for unknown prompt with section" do
      assert {:error, :not_found} =
               PromptLoader.render_section(:nonexistent, :section, %{})
    end
  end

  # ---------------------------------------------------------------
  # get_raw/1
  # ---------------------------------------------------------------

  describe "get_raw/1" do
    setup %{prompts_dir: dir} do
      {:ok, pid} = PromptLoader.start_link(dir: dir)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      :ok
    end

    test "returns raw template string" do
      assert {:ok, raw} = PromptLoader.get_raw(:orchestrator)
      assert raw =~ "<%= @skill_domains %>"
      assert raw =~ "<%= @user_id %>"
    end

    test "returns error for unknown prompt" do
      assert {:error, :not_found} = PromptLoader.get_raw(:nonexistent)
    end
  end

  # ---------------------------------------------------------------
  # Boot behavior
  # ---------------------------------------------------------------

  describe "boot behavior" do
    test "handles missing prompts directory gracefully" do
      # Should not crash — just log warning
      {:ok, pid} = PromptLoader.start_link(dir: "/nonexistent/prompts/dir")
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "handles empty prompts directory" do
      empty_dir = Path.join(System.tmp_dir!(), "empty_prompts_#{System.unique_integer([:positive])}")
      File.mkdir_p!(empty_dir)

      {:ok, pid} = PromptLoader.start_link(dir: empty_dir)
      assert Process.alive?(pid)

      # No prompts loaded — render should return not_found
      assert {:error, :not_found} = PromptLoader.render(:anything)

      GenServer.stop(pid)
      File.rm_rf!(empty_dir)
    end

    test "skips malformed YAML files without crashing", %{prompts_dir: dir} do
      File.write!(Path.join(dir, "broken.yaml"), ": invalid [[[")

      {:ok, pid} = PromptLoader.start_link(dir: dir)
      assert Process.alive?(pid)

      # Good files should still be loaded
      assert {:ok, _} = PromptLoader.get_raw(:orchestrator)

      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------
  # reload/0
  # ---------------------------------------------------------------

  describe "reload/0" do
    test "reloads templates from disk", %{prompts_dir: dir} do
      {:ok, pid} = PromptLoader.start_link(dir: dir)

      # Add a new prompt file
      File.write!(Path.join(dir, "new_prompt.yaml"), """
      system: |
        New prompt: <%= @var %>
      """)

      assert :ok = PromptLoader.reload()
      assert {:ok, rendered} = PromptLoader.render(:new_prompt, %{var: "test"})
      assert rendered =~ "test"

      GenServer.stop(pid)
    end
  end
end
