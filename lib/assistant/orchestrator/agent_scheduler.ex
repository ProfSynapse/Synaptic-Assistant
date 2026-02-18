# lib/assistant/orchestrator/agent_scheduler.ex — DAG dependency resolution for sub-agents.
#
# Takes a list of dispatch params (from dispatch_agent tool calls), resolves
# dependencies into execution waves, and coordinates spawning via
# Task.Supervisor. Each wave contains agents whose dependencies are satisfied;
# waves execute sequentially, agents within a wave execute in parallel.
#
# Works with the get_agent_results yield pattern: when get_agent_results
# returns {:wait, ...}, the Engine uses this scheduler to actually wait
# for the specified agents.
#
# Related files:
#   - lib/assistant/orchestrator/engine.ex (owns the Task.Supervisor)
#   - lib/assistant/orchestrator/tools/dispatch_agent.ex (creates dispatch params)
#   - lib/assistant/orchestrator/tools/get_agent_results.ex (reads results)

defmodule Assistant.Orchestrator.AgentScheduler do
  @moduledoc """
  DAG-based execution scheduler for sub-agent dispatch.

  Resolves the `depends_on` graph into sequential execution waves.
  Agents in the same wave run in parallel via `Task.Supervisor`.
  Agents in later waves receive results from completed dependencies.

  ## Execution Model

      Wave 0: [agent_a, agent_b]  (no dependencies)
      Wave 1: [agent_c]           (depends_on: [agent_a])
      Wave 2: [agent_d]           (depends_on: [agent_b, agent_c])

  If an agent fails, all transitive dependents are marked `:skipped`.
  """

  require Logger

  @default_agent_timeout :timer.seconds(60)
  @max_wave_timeout :timer.seconds(120)

  @doc """
  Plans execution waves from a list of dispatch params.

  Returns an ordered list of waves, where each wave is a list of agent_ids
  that can execute in parallel.

  ## Parameters

    * `dispatches` - Map of agent_id => dispatch_params

  ## Returns

    * `{:ok, waves}` — list of lists of agent_ids
    * `{:error, :cycle_detected}` — dependency graph has a cycle
    * `{:error, :unknown_dependency, dep}` — depends_on references unknown agent
  """
  @spec plan_waves(map()) :: {:ok, [[String.t()]]} | {:error, term()}
  def plan_waves(dispatches) when dispatches == %{}, do: {:ok, []}

  def plan_waves(dispatches) do
    graph = build_graph(dispatches)

    with :ok <- validate_dependencies(dispatches),
         :ok <- validate_acyclic(graph, dispatches) do
      waves = compute_waves(graph, Map.keys(dispatches))
      {:ok, waves}
    end
  end

  @doc """
  Executes all dispatch waves using the given Task.Supervisor.

  Spawns agents in parallel within each wave, waits for completion,
  then proceeds to the next wave with accumulated results.

  ## Parameters

    * `dispatches` - Map of agent_id => dispatch_params
    * `agent_supervisor` - PID of the Task.Supervisor to use
    * `execute_fn` - Function `(dispatch_params, dep_results) -> result`
      that runs a single sub-agent. Called within the Task.

  ## Returns

    * `{:ok, results}` — Map of agent_id => agent_result
    * `{:error, reason}` — Planning or execution failure
  """
  @spec execute(map(), pid(), function()) :: {:ok, map()} | {:error, term()}
  def execute(dispatches, agent_supervisor, execute_fn) do
    case plan_waves(dispatches) do
      {:ok, waves} ->
        results = execute_waves(waves, dispatches, agent_supervisor, execute_fn, %{})
        {:ok, results}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Waits for specific agents to reach terminal states.

  Used by the Engine when get_agent_results returns a {:wait, ...} signal.
  Blocks until the wait condition is met or timeout expires.

  ## Parameters

    * `agent_tasks` - Map of agent_id => Task.t() for running agents
    * `agent_ids` - List of agent_ids to wait for
    * `mode` - `:wait_any` or `:wait_all`
    * `timeout_ms` - Maximum wait time

  ## Returns

    * Map of agent_id => result for agents that completed within the timeout
  """
  @spec wait_for_agents(map(), [String.t()], atom(), pos_integer()) :: map()
  def wait_for_agents(agent_tasks, agent_ids, mode, timeout_ms) do
    relevant_tasks =
      agent_ids
      |> Enum.filter(&Map.has_key?(agent_tasks, &1))
      |> Enum.map(fn id -> {id, Map.fetch!(agent_tasks, id)} end)

    case mode do
      :wait_any ->
        wait_any(relevant_tasks, timeout_ms)

      :wait_all ->
        wait_all(relevant_tasks, timeout_ms)
    end
  end

  # --- Graph Building ---

  defp build_graph(dispatches) do
    Map.new(dispatches, fn {agent_id, params} ->
      deps = params[:depends_on] || params["depends_on"] || []
      {agent_id, deps}
    end)
  end

  defp validate_dependencies(dispatches) do
    all_ids = MapSet.new(Map.keys(dispatches))

    unknown =
      dispatches
      |> Enum.flat_map(fn {_id, params} ->
        deps = params[:depends_on] || params["depends_on"] || []
        Enum.reject(deps, &MapSet.member?(all_ids, &1))
      end)
      |> Enum.uniq()

    case unknown do
      [] -> :ok
      [dep | _] -> {:error, :unknown_dependency, dep}
    end
  end

  defp validate_acyclic(graph, dispatches) do
    # Kahn's algorithm: if we can topologically sort all nodes, no cycle exists
    in_degree =
      Map.new(Map.keys(dispatches), fn id ->
        deps = Map.get(graph, id, [])
        {id, length(deps)}
      end)

    queue =
      in_degree
      |> Enum.filter(fn {_id, deg} -> deg == 0 end)
      |> Enum.map(fn {id, _} -> id end)

    sorted_count = topo_sort_count(queue, graph, in_degree, Map.keys(dispatches), 0)

    if sorted_count == map_size(dispatches) do
      :ok
    else
      {:error, :cycle_detected}
    end
  end

  defp topo_sort_count([], _graph, _in_degree, _all_ids, count), do: count

  defp topo_sort_count([node | rest], graph, in_degree, all_ids, count) do
    # Find nodes that depend on this node
    dependents =
      Enum.filter(all_ids, fn id ->
        deps = Map.get(graph, id, [])
        node in deps
      end)

    {new_queue_additions, new_in_degree} =
      Enum.reduce(dependents, {[], in_degree}, fn dep, {q_acc, deg_acc} ->
        new_deg = Map.get(deg_acc, dep, 0) - 1
        deg_acc = Map.put(deg_acc, dep, new_deg)

        if new_deg == 0 do
          {[dep | q_acc], deg_acc}
        else
          {q_acc, deg_acc}
        end
      end)

    topo_sort_count(rest ++ new_queue_additions, graph, new_in_degree, all_ids, count + 1)
  end

  # --- Wave Computation ---

  defp compute_waves(graph, all_ids) do
    compute_waves(graph, all_ids, MapSet.new(), [])
  end

  defp compute_waves(graph, all_ids, completed, waves) do
    remaining = Enum.reject(all_ids, &MapSet.member?(completed, &1))

    if remaining == [] do
      Enum.reverse(waves)
    else
      ready =
        Enum.filter(remaining, fn id ->
          deps = Map.get(graph, id, [])
          Enum.all?(deps, &MapSet.member?(completed, &1))
        end)

      if ready == [] do
        # Should not happen if graph is acyclic — fallback
        Enum.reverse(waves)
      else
        new_completed = Enum.reduce(ready, completed, &MapSet.put(&2, &1))
        compute_waves(graph, all_ids, new_completed, [ready | waves])
      end
    end
  end

  # --- Wave Execution ---

  defp execute_waves([], _dispatches, _supervisor, _execute_fn, results), do: results

  defp execute_waves([wave | rest], dispatches, supervisor, execute_fn, results) do
    # Spawn all agents in this wave concurrently
    tasks =
      Enum.map(wave, fn agent_id ->
        dispatch = Map.fetch!(dispatches, agent_id)
        dep_results = get_dependency_results(dispatch, results)

        task =
          Task.Supervisor.async_nolink(
            supervisor,
            fn -> execute_fn.(dispatch, dep_results) end,
            timeout: agent_timeout(dispatch)
          )

        {agent_id, task}
      end)

    # Wait for all tasks in this wave
    task_list = Enum.map(tasks, fn {_id, task} -> task end)
    yields = Task.yield_many(task_list, timeout: @max_wave_timeout)

    # Collect results
    wave_results =
      Enum.zip(tasks, yields)
      |> Enum.into(%{}, fn {{agent_id, _task}, {_task_ref, result}} ->
        {agent_id, normalize_result(agent_id, result)}
      end)

    # Handle failures: skip transitive dependents
    {wave_results, skipped} = handle_wave_failures(wave_results, rest, dispatches)
    all_results = results |> Map.merge(wave_results) |> Map.merge(skipped)

    # Filter out skipped agents from remaining waves
    remaining_waves = remove_skipped_from_waves(rest, skipped)

    execute_waves(remaining_waves, dispatches, supervisor, execute_fn, all_results)
  end

  defp get_dependency_results(dispatch, completed_results) do
    deps = dispatch[:depends_on] || dispatch["depends_on"] || []

    Enum.reduce(deps, %{}, fn dep_id, acc ->
      case Map.get(completed_results, dep_id) do
        nil -> acc
        result -> Map.put(acc, dep_id, result)
      end
    end)
  end

  defp agent_timeout(dispatch) do
    dispatch[:timeout_ms] || @default_agent_timeout
  end

  defp normalize_result(agent_id, result) do
    case result do
      {:ok, agent_result} when is_map(agent_result) ->
        agent_result

      {:exit, reason} ->
        Logger.error("Agent crashed", agent_id: agent_id, reason: inspect(reason))

        %{
          status: :failed,
          result: "Agent crashed: #{inspect(reason)}",
          tool_calls_used: 0
        }

      nil ->
        Logger.warning("Agent timed out", agent_id: agent_id)

        %{
          status: :timeout,
          result: "Agent timed out",
          tool_calls_used: 0
        }
    end
  end

  defp handle_wave_failures(wave_results, remaining_waves, dispatches) do
    failed_ids =
      wave_results
      |> Enum.filter(fn {_id, result} -> result[:status] in [:failed, :timeout] end)
      |> Enum.map(fn {id, _} -> id end)
      |> MapSet.new()

    if MapSet.size(failed_ids) == 0 do
      {wave_results, %{}}
    else
      # Find all agents in remaining waves that transitively depend on failed agents
      remaining_ids =
        remaining_waves
        |> List.flatten()

      skipped =
        find_transitive_dependents(failed_ids, remaining_ids, dispatches)
        |> Enum.into(%{}, fn id ->
          dep_chain =
            failed_ids
            |> MapSet.to_list()
            |> Enum.join(", ")

          {id,
           %{
             status: :skipped,
             result: "Skipped because dependency failed: #{dep_chain}",
             tool_calls_used: 0
           }}
        end)

      {wave_results, skipped}
    end
  end

  defp find_transitive_dependents(failed_ids, remaining_ids, dispatches) do
    # BFS to find all transitive dependents
    find_dependents_recursive(failed_ids, remaining_ids, dispatches, MapSet.new())
    |> MapSet.to_list()
  end

  defp find_dependents_recursive(blocked_ids, remaining_ids, dispatches, skipped) do
    newly_blocked =
      Enum.filter(remaining_ids, fn id ->
        not MapSet.member?(skipped, id) and
          not MapSet.member?(blocked_ids, id) and
          has_blocked_dependency?(id, blocked_ids, skipped, dispatches)
      end)
      |> MapSet.new()

    if MapSet.size(newly_blocked) == 0 do
      skipped
    else
      new_skipped = MapSet.union(skipped, newly_blocked)
      all_blocked = MapSet.union(blocked_ids, newly_blocked)
      find_dependents_recursive(all_blocked, remaining_ids, dispatches, new_skipped)
    end
  end

  defp has_blocked_dependency?(id, blocked_ids, skipped, dispatches) do
    dispatch = Map.get(dispatches, id, %{})
    deps = dispatch[:depends_on] || dispatch["depends_on"] || []

    Enum.any?(deps, fn dep ->
      MapSet.member?(blocked_ids, dep) or MapSet.member?(skipped, dep)
    end)
  end

  defp remove_skipped_from_waves(waves, skipped) do
    skipped_ids = Map.keys(skipped) |> MapSet.new()

    waves
    |> Enum.map(fn wave ->
      Enum.reject(wave, &MapSet.member?(skipped_ids, &1))
    end)
    |> Enum.reject(&(&1 == []))
  end

  # --- Wait Helpers ---

  defp wait_any([], _timeout_ms), do: %{}

  defp wait_any(task_pairs, timeout_ms) do
    tasks = Enum.map(task_pairs, fn {_id, task} -> task end)
    yields = Task.yield_many(tasks, timeout: timeout_ms)

    Enum.zip(task_pairs, yields)
    |> Enum.reduce(%{}, fn {{agent_id, _task}, {_task_ref, result}}, acc ->
      case result do
        {:ok, agent_result} ->
          Map.put(acc, agent_id, agent_result)

        {:exit, reason} ->
          Map.put(acc, agent_id, %{
            status: :failed,
            result: "Agent crashed: #{inspect(reason)}",
            tool_calls_used: 0
          })

        nil ->
          # Not done yet — don't include
          acc
      end
    end)
  end

  defp wait_all([], _timeout_ms), do: %{}

  defp wait_all(task_pairs, timeout_ms) do
    tasks = Enum.map(task_pairs, fn {_id, task} -> task end)
    yields = Task.yield_many(tasks, timeout: timeout_ms)

    Enum.zip(task_pairs, yields)
    |> Enum.into(%{}, fn {{agent_id, _task}, {_task_ref, result}} ->
      {agent_id, normalize_result(agent_id, result)}
    end)
  end
end
