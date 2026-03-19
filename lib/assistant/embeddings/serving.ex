# lib/assistant/embeddings/serving.ex
# Manages the Nx.Serving process for text embeddings via Bumblebee/gte-small.
# Loads the HuggingFace model asynchronously so the app starts even if
# HuggingFace is unreachable. Retries with exponential backoff on failure.
# Used by Assistant.Embeddings.generate/1 and generate_batch/1 via
# Nx.Serving.batched_run(Assistant.Embeddings, text).
defmodule Assistant.Embeddings.Serving do
  @moduledoc false

  use GenServer
  require Logger

  @model_repo {:hf, "thenlper/gte-small"}
  @max_retries 5
  @initial_backoff_ms 2_000

  # -------------------------------------------------------------------
  # Supervision entry point
  # -------------------------------------------------------------------

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # -------------------------------------------------------------------
  # GenServer callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %{serving_pid: nil, attempt: 0}, {:continue, :load_model}}
  end

  @impl true
  def handle_continue(:load_model, state) do
    load_and_start(state)
  end

  @impl true
  def handle_info(:retry_load, state) do
    load_and_start(state)
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{serving_pid: pid} = state) do
    Logger.warning("Nx.Serving process exited: #{inspect(reason)}. Restarting model load.")
    {:noreply, %{state | serving_pid: nil, attempt: 0}, {:continue, :load_model}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # -------------------------------------------------------------------
  # Internal
  # -------------------------------------------------------------------

  defp load_and_start(%{attempt: attempt} = state) do
    Logger.info("Loading embedding model (attempt #{attempt + 1}/#{@max_retries + 1})...")

    case load_model() do
      {:ok, serving} ->
        Logger.info("Embedding model loaded successfully.")
        pid = start_serving!(serving)
        Process.monitor(pid)
        {:noreply, %{state | serving_pid: pid, attempt: 0}}

      {:error, reason} when attempt < @max_retries ->
        backoff = backoff_ms(attempt)

        Logger.warning(
          "Failed to load embedding model: #{inspect(reason)}. " <>
            "Retrying in #{backoff}ms (attempt #{attempt + 1}/#{@max_retries + 1})."
        )

        Process.send_after(self(), :retry_load, backoff)
        {:noreply, %{state | attempt: attempt + 1}}

      {:error, reason} ->
        Logger.error(
          "Failed to load embedding model after #{@max_retries + 1} attempts: #{inspect(reason)}. " <>
            "Embeddings will be unavailable. Restart the application to retry."
        )

        {:noreply, %{state | attempt: 0}}
    end
  end

  defp load_model do
    model_info = Bumblebee.load_model(@model_repo)
    tokenizer = Bumblebee.load_tokenizer(@model_repo)

    case {model_info, tokenizer} do
      {{:ok, model}, {:ok, tok}} ->
        serving =
          Bumblebee.Text.TextEmbedding.text_embedding(model, tok,
            output_pool: :mean_pooling,
            output_attribute: :hidden_state,
            embedding_processor: :l2_norm,
            compile: [batch_size: 32, sequence_length: 512],
            defn_options: [compiler: EXLA]
          )

        {:ok, serving}

      {{:error, reason}, _} ->
        {:error, {:model_load_failed, reason}}

      {_, {:error, reason}} ->
        {:error, {:tokenizer_load_failed, reason}}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  defp start_serving!(serving) do
    {:ok, pid} =
      Nx.Serving.start_link(
        serving: serving,
        name: Assistant.Embeddings,
        batch_size: 32,
        batch_timeout: 100
      )

    pid
  end

  defp backoff_ms(attempt) do
    @initial_backoff_ms * Integer.pow(2, attempt)
  end
end
