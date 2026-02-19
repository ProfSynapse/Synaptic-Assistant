defmodule Assistant.OrchestratorSystemPromptTest do
  use ExUnit.Case, async: false

  alias Assistant.OrchestratorSystemPrompt

  setup do
    original = Application.get_env(:assistant, :orchestrator_system_prompt_path)

    path =
      Path.join(
        System.tmp_dir!(),
        "orchestrator_system_prompt_test_#{System.unique_integer([:positive])}.md"
      )

    File.rm(path)
    Application.put_env(:assistant, :orchestrator_system_prompt_path, path)

    on_exit(fn ->
      File.rm(path)

      if original do
        Application.put_env(:assistant, :orchestrator_system_prompt_path, original)
      else
        Application.delete_env(:assistant, :orchestrator_system_prompt_path)
      end
    end)

    {:ok, path: path}
  end

  test "get_prompt/0 returns empty string when file is missing" do
    assert OrchestratorSystemPrompt.get_prompt() == ""
  end

  test "save_prompt/1 writes prompt content and get_prompt/0 returns it", %{path: path} do
    assert :ok = OrchestratorSystemPrompt.save_prompt("Be concise and direct.")
    assert File.exists?(path)
    assert OrchestratorSystemPrompt.get_prompt() == "Be concise and direct."
  end

  test "save_prompt/1 with blank content clears persisted prompt", %{path: path} do
    assert :ok = OrchestratorSystemPrompt.save_prompt("Temporary")
    assert File.exists?(path)

    assert :ok = OrchestratorSystemPrompt.save_prompt("   ")
    refute File.exists?(path)
    assert OrchestratorSystemPrompt.get_prompt() == ""
  end
end
