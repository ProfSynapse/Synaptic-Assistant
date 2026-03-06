defmodule Assistant.Orchestrator.SubAgentQuery do
  @moduledoc """
  Snapshot-based question answering over sub-agent progress.

  Runs a separate LLM call against a bounded sub-agent snapshot and returns a
  structured answer without interrupting or mutating the target agent.
  """

  alias Assistant.Integrations.LLMRouter
  alias Assistant.Orchestrator.LLMHelpers

  @response_format %{
    type: "json_schema",
    json_schema: %{
      name: "subagent_query",
      strict: true,
      schema: %{
        type: "object",
        properties: %{
          summary: %{type: "string"},
          answer: %{type: "string"},
          progress: %{type: "string"},
          blockers: %{type: "array", items: %{type: "string"}},
          open_questions: %{type: "array", items: %{type: "string"}}
        },
        required: ["summary", "answer", "progress", "blockers", "open_questions"],
        additionalProperties: false
      }
    }
  }

  @system_prompt """
  You answer questions about another sub-agent's progress from a point-in-time snapshot.

  Rules:
  - Use only the provided snapshot.
  - Do not invent work the agent has not shown.
  - If the snapshot is incomplete, say so in the answer and open_questions.
  - Be concise and operational.
  """

  @spec query(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def query(snapshot, question, opts \\ []) when is_binary(question) do
    user_id = Keyword.get(opts, :user_id)
    model = LLMHelpers.resolve_model(:sub_agent, user_id: user_id)

    messages = [
      %{role: "system", content: @system_prompt},
      %{role: "user", content: build_prompt(snapshot, question)}
    ]

    case LLMRouter.chat_completion(
           messages,
           [
             model: model,
             temperature: 0.0,
             max_tokens: 800,
             response_format: @response_format
           ],
           user_id
         ) do
      {:ok, %{content: content}} when is_binary(content) ->
        parse_response(content)

      {:ok, %{content: nil}} ->
        {:error, :nil_content}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_prompt(snapshot, question) do
    transcript =
      snapshot
      |> Map.get(:messages, [])
      |> Enum.map_join("\n\n---\n\n", &format_snapshot_message/1)

    """
    Target agent id: #{snapshot[:agent_id] || "unknown"}
    Mission: #{snapshot[:mission] || "(unknown)"}
    Status: #{snapshot[:status] || "unknown"}
    Tool calls used: #{snapshot[:tool_calls_used] || 0}
    Last result: #{snapshot[:result] || "(none)"}

    Transcript snapshot:
    #{transcript}

    Question:
    #{question}
    """
    |> String.trim()
  end

  defp parse_response(content) do
    cleaned =
      content
      |> String.trim()
      |> String.replace(~r/^```json\s*/, "")
      |> String.replace(~r/\s*```$/, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok,
       %{
         "summary" => summary,
         "answer" => answer,
         "progress" => progress,
         "blockers" => blockers,
         "open_questions" => open_questions
       }}
      when is_binary(summary) and is_binary(answer) and is_binary(progress) and is_list(blockers) and
             is_list(open_questions) ->
        {:ok,
         %{
           summary: summary,
           answer: answer,
           progress: progress,
           blockers: blockers,
           open_questions: open_questions
         }}

      {:ok, other} ->
        {:error, {:unexpected_shape, other}}

      {:error, reason} ->
        {:error, {:json_decode_failed, reason}}
    end
  end

  defp format_snapshot_message(%{role: "assistant", tool_calls: tool_calls} = msg)
       when is_list(tool_calls) and tool_calls != [] do
    calls_text =
      Enum.map_join(tool_calls, "\n", fn tc ->
        name = get_in(tc, [:function, :name]) || get_in(tc, ["function", "name"]) || "unknown"
        args = get_in(tc, [:function, :arguments]) || get_in(tc, ["function", "arguments"]) || ""
        "[tool_call] #{name}: #{args}"
      end)

    case msg[:content] do
      nil -> "[assistant]\n#{calls_text}"
      "" -> "[assistant]\n#{calls_text}"
      text -> "[assistant] #{text}\n#{calls_text}"
    end
  end

  defp format_snapshot_message(%{role: role, content: content}), do: "[#{role}] #{content}"
  defp format_snapshot_message(%{role: role}), do: "[#{role}]"
end
