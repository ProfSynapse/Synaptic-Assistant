# lib/assistant/skills/workflow/helpers.ex — Shared helpers for workflow skills.
#
# Centralizes the resolve_workflows_dir/0 function that was previously
# duplicated across create.ex, list.ex, run.ex, and cancel.ex.
#
# Related files:
#   - lib/assistant/skills/workflow/create.ex
#   - lib/assistant/skills/workflow/list.ex
#   - lib/assistant/skills/workflow/run.ex
#   - lib/assistant/skills/workflow/cancel.ex
#   - lib/assistant/scheduler/quantum_loader.ex (also uses this pattern)

defmodule Assistant.Skills.Workflow.Helpers do
  @moduledoc """
  Shared utility functions for workflow skill handlers.
  """

  @workflows_dir Application.compile_env(:assistant, :workflows_dir, "priv/workflows")

  @doc """
  Resolves the absolute path to the workflows directory.

  Uses the `:workflows_dir` application env if set at runtime,
  otherwise falls back to the compile-time default joined with
  the application directory.
  """
  def resolve_workflows_dir do
    case Application.get_env(:assistant, :workflows_dir) do
      nil -> Path.join(Application.app_dir(:assistant), @workflows_dir)
      dir -> dir
    end
  end
end
