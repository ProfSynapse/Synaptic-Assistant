defmodule Assistant.OrchestratorSystemPrompt do
  @moduledoc """
  File-backed custom system prompt fragment for the orchestrator.
  """

  @default_path "config/orchestrator_system_prompt.md"

  @spec get_prompt() :: String.t()
  def get_prompt do
    path = prompt_path()

    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} -> String.trim(content)
        {:error, _reason} -> ""
      end
    else
      ""
    end
  rescue
    _ -> ""
  end

  @spec save_prompt(String.t()) :: :ok | {:error, term()}
  def save_prompt(content) when is_binary(content) do
    trimmed = String.trim(content)
    path = prompt_path()
    File.mkdir_p!(Path.dirname(path))

    if trimmed == "" do
      if File.exists?(path) do
        File.rm(path)
      else
        :ok
      end
    else
      File.write(path, trimmed <> "\n")
    end
  rescue
    exception ->
      {:error, exception}
  end

  defp prompt_path do
    Application.get_env(:assistant, :orchestrator_system_prompt_path, @default_path)
  end
end
