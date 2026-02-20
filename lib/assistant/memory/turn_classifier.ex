# lib/assistant/memory/turn_classifier.ex — Conversation turn classifier.
#
# GenServer that subscribes to PubSub turn completion events from the
# orchestrator engine. For each completed turn, makes a lightweight LLM
# classification call to determine if the exchange contains memorable facts,
# signals a topic change, or is routine. Dispatches appropriate missions to
# the user's memory agent based on classification result.
#
# Related files:
#   - lib/assistant/orchestrator/engine.ex (publishes :turn_completed events)
#   - lib/assistant/memory/agent.ex (receives save_memory/compact missions)
#   - lib/assistant/integrations/openrouter.ex (LLM client for classification)
#   - lib/assistant/config/loader.ex (model selection for sentinel/fast tier)
#   - lib/assistant/application.ex (supervision tree)

defmodule Assistant.Memory.TurnClassifier do
  @moduledoc """
  Classifies conversation turns for memory worthiness.

  Subscribes to PubSub topic `"memory:turn_completed"`. For each turn,
  makes a cheap LLM classification call (sentinel-tier model) to decide:

    * `save_facts` — Exchange contains new facts about named entities.
      Dispatches `save_memory` + `extract_entities` to the memory agent.
    * `compact` — Clear topic change detected. Dispatches
      `compact_conversation` to the memory agent.
    * `nothing` — Routine exchange, no action needed.

  Classification runs asynchronously via Task.Supervisor to avoid blocking
  the GenServer on LLM latency.
  """

  use GenServer

  require Logger

  alias Assistant.Config.Loader, as: ConfigLoader

  @llm_client Application.compile_env(
                :assistant,
                :llm_client,
                Assistant.Integrations.OpenRouter
              )

  @classification_prompt """
  Classify this conversation exchange.

  save_facts: exchange contains new facts about named entities (people, orgs, projects)
  compact: clear topic change from what was previously discussed
  nothing: routine exchange, no new memorable facts

  User: {{user_message}}
  Assistant: {{assistant_response}}
  """

  @classification_response_format %{
    type: "json_schema",
    json_schema: %{
      name: "turn_classification",
      strict: true,
      schema: %{
        type: "object",
        properties: %{
          action: %{
            type: "string",
            enum: ["save_facts", "compact", "nothing"],
            description: "Classification action for this conversation turn"
          },
          reason: %{
            type: "string",
            description: "One-line explanation for the classification"
          }
        },
        required: ["action", "reason"],
        additionalProperties: false
      }
    }
  }

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Assistant.PubSub, "memory:turn_completed")
    {:ok, %{}}
  end

  @impl true
  def handle_info(
        {:turn_completed,
         %{
           conversation_id: conversation_id,
           user_id: user_id,
           user_message: user_message,
           assistant_response: assistant_response
         }},
        state
      ) do
    # Run classification asynchronously to avoid blocking the GenServer
    Task.Supervisor.start_child(Assistant.Skills.TaskSupervisor, fn ->
      classify_and_dispatch(conversation_id, user_id, user_message, assistant_response)
    end)

    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Internal ---

  defp classify_and_dispatch(conversation_id, user_id, user_message, assistant_response) do
    prompt =
      @classification_prompt
      |> String.replace("{{user_message}}", truncate(user_message, 2000))
      |> String.replace("{{assistant_response}}", truncate(assistant_response, 2000))

    model = resolve_classification_model()

    messages = [
      %{role: "user", content: prompt}
    ]

    Logger.debug("Turn classification using model", model: model, conversation_id: conversation_id)

    case @llm_client.chat_completion(messages,
           model: model,
           temperature: 0.0,
           max_tokens: 500,
           response_format: @classification_response_format
         ) do
      {:ok, %{content: content}} ->
        handle_classification(content, conversation_id, user_id, user_message, assistant_response)

      {:error, reason} ->
        Logger.warning("Turn classification failed, skipping",
          conversation_id: conversation_id,
          model: model,
          reason: inspect(reason)
        )
    end
  end

  defp handle_classification(content, conversation_id, user_id, user_message, assistant_response) do
    case parse_classification(content) do
      {:ok, "save_facts", reason} ->
        Logger.info("Turn classified as save_facts",
          conversation_id: conversation_id,
          reason: reason
        )

        dispatch_to_memory_agent(user_id, :save_and_extract, %{
          conversation_id: conversation_id,
          user_id: user_id,
          user_message: user_message,
          assistant_response: assistant_response,
          trigger: :turn_classifier,
          classification_reason: reason
        })

      {:ok, "compact", reason} ->
        Logger.info("Turn classified as compact (topic change)",
          conversation_id: conversation_id,
          reason: reason
        )

        dispatch_to_memory_agent(user_id, :compact_conversation, %{
          conversation_id: conversation_id,
          user_id: user_id,
          trigger: :turn_classifier_topic_change,
          classification_reason: reason
        })

      {:ok, "nothing", _reason} ->
        Logger.debug("Turn classified as nothing, no action",
          conversation_id: conversation_id
        )

      {:error, reason} ->
        Logger.warning("Failed to parse classification response",
          conversation_id: conversation_id,
          content: content,
          reason: inspect(reason)
        )
    end
  end

  defp parse_classification(content) when is_binary(content) do
    # Strip markdown code fences if present
    cleaned =
      content
      |> String.trim()
      |> String.replace(~r/^```json\s*/, "")
      |> String.replace(~r/\s*```$/, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, %{"action" => action, "reason" => reason}}
      when action in ["save_facts", "compact", "nothing"] ->
        {:ok, action, reason}

      {:ok, %{"action" => action}} ->
        {:error, {:invalid_action, action}}

      {:error, decode_error} ->
        {:error, {:json_decode_failed, decode_error}}
    end
  end

  defp parse_classification(_), do: {:error, :nil_content}

  defp dispatch_to_memory_agent(user_id, mission, params) do
    case Registry.lookup(Assistant.SubAgent.Registry, {:memory_agent, user_id}) do
      [{pid, _value}] ->
        GenServer.cast(pid, {:mission, mission, params})

      [] ->
        Logger.warning("Memory agent not found for user, skipping #{mission}",
          user_id: user_id
        )
    end
  end

  @hardcoded_fallback_model "openai/gpt-5-mini"

  defp resolve_classification_model do
    # Prefer sentinel role (cheapest fast-tier model), fall back to compaction, then hardcoded
    case ConfigLoader.model_for(:sentinel) do
      %{id: id} ->
        id

      nil ->
        case ConfigLoader.model_for(:compaction) do
          %{id: id} -> id
          nil -> @hardcoded_fallback_model
        end
    end
  rescue
    _error ->
      Logger.warning("ConfigLoader unavailable for classification model, using hardcoded fallback")
      @hardcoded_fallback_model
  end

  defp truncate(text, max_length) when is_binary(text) do
    if String.length(text) > max_length do
      String.slice(text, 0, max_length) <> "..."
    else
      text
    end
  end

  defp truncate(nil, _max_length), do: ""
end
