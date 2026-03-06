defmodule Assistant.Orchestrator.Tools.QuerySubagent do
  @moduledoc """
  Orchestrator tool for querying another sub-agent's snapshot without
  interrupting it.
  """

  alias Assistant.Orchestrator.{SubAgent, SubAgentQuery}

  @doc """
  Returns the OpenAI-compatible function tool definition for query_subagent.
  """
  @spec tool_definition() :: map()
  def tool_definition do
    %{
      name: "query_subagent",
      description: """
      Ask a focused question about a sub-agent's current progress without
      interrupting it. This reads the agent's snapshot and returns a structured
      answer synthesized by a separate LLM call.\
      """,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "agent_id" => %{
            "type" => "string",
            "description" => "The target sub-agent to inspect."
          },
          "question" => %{
            "type" => "string",
            "description" => "The concrete question to answer about the target agent."
          }
        },
        "required" => ["agent_id", "question"]
      }
    }
  end

  @spec execute(map(), map()) :: {:ok, Assistant.Skills.Result.t()}
  def execute(params, loop_state) do
    with {:ok, agent_id} <- fetch_string(params, "agent_id"),
         {:ok, question} <- fetch_string(params, "question"),
         {:ok, snapshot} <- load_snapshot(agent_id, loop_state),
         {:ok, answer} <- SubAgentQuery.query(snapshot, question, user_id: loop_state[:user_id]) do
      content = """
      Summary: #{answer.summary}

      Answer: #{answer.answer}

      Progress: #{answer.progress}

      Blockers: #{format_list(answer.blockers)}

      Open questions: #{format_list(answer.open_questions)}
      """

      {:ok,
       %Assistant.Skills.Result{
         status: :ok,
         content: String.trim(content),
         metadata: %{
           agent_id: agent_id,
           answer: answer
         }
       }}
    else
      {:error, :not_found} ->
        {:ok,
         %Assistant.Skills.Result{
           status: :error,
           content: "Agent not found. It may have already exited and no snapshot is available."
         }}

      {:error, {:missing, field}} ->
        {:ok,
         %Assistant.Skills.Result{
           status: :error,
           content: "Missing required field: #{field}"
         }}

      {:error, reason} ->
        {:ok,
         %Assistant.Skills.Result{
           status: :error,
           content: "Query failed: #{inspect(reason)}"
         }}
    end
  end

  defp load_snapshot(agent_id, loop_state) do
    case SubAgent.get_snapshot(agent_id) do
      {:ok, snapshot} ->
        {:ok, snapshot}

      {:error, :not_found} ->
        case get_in(loop_state, [:dispatched_agents, agent_id]) do
          %{messages: messages} = result_map when is_list(messages) ->
            {:ok,
             %{
               agent_id: agent_id,
               mission: result_map[:mission],
               status: result_map[:status],
               result: result_map[:result],
               tool_calls_used: result_map[:tool_calls_used],
               messages: messages
             }}

          _ ->
            {:error, :not_found}
        end
    end
  end

  defp fetch_string(params, key) do
    case params[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing, key}}
    end
  end

  defp format_list([]), do: "(none)"
  defp format_list(items), do: Enum.join(items, "; ")
end
