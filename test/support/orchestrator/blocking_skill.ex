defmodule Assistant.TestSupport.Orchestrator.BlockingSkill do
  @moduledoc false

  @behaviour Assistant.Skills.Handler

  alias Assistant.Skills.Result

  @impl true
  def execute(_flags, context) do
    notify_pid = Application.get_env(:assistant, :blocking_skill_notify_pid)

    if is_pid(notify_pid) do
      send(notify_pid, {:blocking_skill_started, self(), context.metadata[:agent_id]})
    end

    receive do
      :release ->
        {:ok, %Result{status: :ok, content: "Blocking skill released."}}
    after
      5_000 ->
        {:ok, %Result{status: :ok, content: "Blocking skill timed out."}}
    end
  end
end
