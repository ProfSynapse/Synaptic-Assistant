# lib/assistant/skills/executor.ex — Task.Supervisor-based skill execution.
#
# Executes skill handlers as supervised async tasks with configurable
# timeouts. Skills run in-process under Task.Supervisor — no external
# sandbox needed because skills are pre-built Elixir modules.
# Used by the orchestrator's agent loop to dispatch skill calls.

defmodule Assistant.Skills.Executor do
  @moduledoc """
  Executes skill handlers as supervised async tasks with timeouts.

  Each skill execution runs under `Assistant.Skills.TaskSupervisor`
  as an unlinked task. If the task crashes or times out, the executor
  captures the failure and returns a structured error — the calling
  process is never affected.

  ## Configuration

  The default timeout is 30 seconds, configurable per execution:

      Executor.execute(handler_module, flags, context, timeout: 60_000)
  """

  alias Assistant.Analytics
  alias Assistant.Skills.{Context, Result}

  require Logger

  @default_timeout :timer.seconds(30)
  @task_supervisor Assistant.Skills.TaskSupervisor

  @doc """
  Execute a skill handler with the given flags and context.

  Spawns a supervised task that calls `handler.execute(flags, context)`.
  Waits up to `timeout` milliseconds for a result. On timeout, the task
  is shut down gracefully.

  ## Parameters

    - `handler` - Module implementing `Assistant.Skills.Handler`
    - `flags` - Parsed CLI flags map
    - `context` - `%Assistant.Skills.Context{}` for this execution
    - `opts` - Keyword options:
      - `:timeout` - Max wait in ms (default: 30,000)

  ## Returns

    - `{:ok, %Result{}}` on success
    - `{:error, :timeout}` if the handler exceeds the timeout
    - `{:error, {:skill_crash, reason}}` if the handler crashes
    - `{:error, reason}` if the handler returns an error tuple
  """
  @spec execute(module(), map(), Context.t(), keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  def execute(handler, flags, context, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    start_time = System.monotonic_time(:millisecond)

    task =
      Task.Supervisor.async_nolink(
        @task_supervisor,
        fn -> handler.execute(flags, context) end
      )

    result = Task.yield(task, timeout) || Task.shutdown(task)
    duration_ms = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, {:ok, %Result{} = skill_result}} ->
        if skill_result.status == :error do
          record_tool_analytics(handler, context, duration_ms, :error, skill_result.content)

          Logger.warning("Skill returned error result",
            handler: inspect(handler),
            content: String.slice(skill_result.content || "", 0, 200),
            duration_ms: duration_ms,
            conversation_id: context.conversation_id
          )
        else
          record_tool_analytics(handler, context, duration_ms, :ok)

          Logger.info("Skill executed successfully",
            handler: inspect(handler),
            duration_ms: duration_ms,
            conversation_id: context.conversation_id
          )
        end

        {:ok, skill_result}

      {:ok, {:error, reason}} ->
        record_tool_analytics(handler, context, duration_ms, :error, reason)

        Logger.warning("Skill returned error",
          handler: inspect(handler),
          reason: inspect(reason),
          duration_ms: duration_ms,
          conversation_id: context.conversation_id
        )

        {:error, reason}

      {:exit, reason} ->
        record_tool_analytics(handler, context, duration_ms, :crash, reason)

        Logger.error("Skill crashed",
          handler: inspect(handler),
          reason: inspect(reason),
          duration_ms: duration_ms,
          conversation_id: context.conversation_id
        )

        {:error, {:skill_crash, reason}}

      nil ->
        record_tool_analytics(handler, context, duration_ms, :timeout)

        Logger.warning("Skill timed out",
          handler: inspect(handler),
          timeout_ms: timeout,
          conversation_id: context.conversation_id
        )

        {:error, :timeout}
    end
  end

  defp record_tool_analytics(handler, context, duration_ms, status, reason \\ nil) do
    metadata =
      case reason do
        nil -> %{}
        _ -> %{reason: inspect(reason)}
      end

    Analytics.record_tool_call(%{
      status: status,
      scope: "skill_executor",
      tool_name: inspect(handler),
      conversation_id: context.conversation_id,
      user_id: context.user_id,
      duration_ms: duration_ms,
      metadata: metadata
    })
  end
end
