defmodule Assistant.Skills.Agents.QuerySubagent do
  @moduledoc """
  Skill handler for querying a sibling sub-agent's snapshot without
  interrupting the target.
  """

  @behaviour Assistant.Skills.Handler

  alias Assistant.Orchestrator.{SubAgent, SubAgentQuery}
  alias Assistant.Skills.Result

  @impl true
  def execute(flags, context) do
    with {:ok, target_agent_id} <- fetch_required(flags, "agent_id"),
         {:ok, question} <- fetch_required(flags, "question"),
         :ok <- reject_self_query(target_agent_id, context),
         {:ok, snapshot} <- SubAgent.get_snapshot(target_agent_id),
         {:ok, answer} <- SubAgentQuery.query(snapshot, question, user_id: context.user_id) do
      {:ok,
       %Result{
         status: :ok,
         content:
           """
           Summary: #{answer.summary}

           Answer: #{answer.answer}

           Progress: #{answer.progress}

           Blockers: #{format_list(answer.blockers)}

           Open questions: #{format_list(answer.open_questions)}
           """
           |> String.trim(),
         metadata: %{agent_id: target_agent_id, answer: answer}
       }}
    else
      {:error, {:missing, field}} ->
        {:ok, %Result{status: :error, content: "Missing required field: #{field}"}}

      {:error, :self_query_not_allowed} ->
        {:ok,
         %Result{
           status: :error,
           content: "Use your own transcript directly; do not query yourself."
         }}

      {:error, :not_found} ->
        {:ok,
         %Result{
           status: :error,
           content: "Target sub-agent not found or no live snapshot is available."
         }}

      {:error, reason} ->
        {:ok, %Result{status: :error, content: "Sub-agent query failed: #{inspect(reason)}"}}
    end
  end

  defp fetch_required(flags, key) do
    case flags[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing, key}}
    end
  end

  defp reject_self_query(target_agent_id, context) do
    if context.metadata[:agent_id] == target_agent_id do
      {:error, :self_query_not_allowed}
    else
      :ok
    end
  end

  defp format_list([]), do: "(none)"
  defp format_list(items), do: Enum.join(items, "; ")
end
