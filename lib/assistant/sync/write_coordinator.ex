defmodule Assistant.Sync.WriteCoordinator do
  @moduledoc """
  Coordinates outbound Google write operations with optional lease enforcement
  and bounded retries for transient failures.

  This module is intentionally generic: callers provide the write callback and
  an optional error classifier function.
  """

  require Logger

  @default_max_retries 2

  @type classify_result :: :conflict | :transient | :fatal

  @spec execute((-> {:ok, term()} | {:error, term()}), keyword()) ::
          {:ok, term()} | {:error, term()}
  def execute(operation_fun, opts \\ []) when is_function(operation_fun, 0) do
    user_id = Keyword.get(opts, :user_id, "unknown")
    file_id = Keyword.get(opts, :file_id, "unknown")
    intent_id = Keyword.get(opts, :intent_id)

    base_metadata = %{user_id: user_id, file_id: file_id, intent_id: intent_id}
    emit_event(:attempt, %{count: 1}, base_metadata, opts)

    wrapped = fn ->
      attempt_execute(operation_fun, opts, 0, base_metadata)
    end

    if lease_enforcement_enabled?() do
      lock_key = {__MODULE__, user_id, file_id}
      :global.trans(lock_key, wrapped)
    else
      wrapped.()
    end
  end

  defp attempt_execute(operation_fun, opts, attempt, base_metadata) do
    max_retries = Keyword.get(opts, :max_retries, @default_max_retries)
    classify_error = Keyword.get(opts, :classify_error, &default_classify_error/1)
    intent_id = Keyword.get(opts, :intent_id)

    case operation_fun.() do
      {:ok, _} = ok ->
        emit_event(:success, %{attempt: attempt}, base_metadata, opts)
        ok

      {:error, reason} = error ->
        case classify_error.(reason) do
          :transient when attempt < max_retries ->
            backoff_ms = retry_backoff_ms(attempt)

            Logger.warning("WriteCoordinator transient failure; retrying",
              attempt: attempt + 1,
              max_retries: max_retries,
              backoff_ms: backoff_ms,
              intent_id: intent_id,
              reason: inspect(reason)
            )

            emit_event(
              :retry,
              %{attempt: attempt + 1, backoff_ms: backoff_ms},
              Map.put(base_metadata, :reason, inspect(reason)),
              opts
            )

            Process.sleep(backoff_ms)
            attempt_execute(operation_fun, opts, attempt + 1, base_metadata)

          _ ->
            emit_event(
              :failure,
              %{attempt: attempt},
              Map.merge(base_metadata, %{
                result_type: classify_error.(reason),
                reason: inspect(reason)
              }),
              opts
            )

            error
        end
    end
  end

  defp default_classify_error(:conflict), do: :conflict
  defp default_classify_error(_), do: :fatal

  defp retry_backoff_ms(0), do: 250 + jitter()
  defp retry_backoff_ms(_), do: 1000 + jitter()

  defp jitter do
    :rand.uniform(100) - 1
  end

  defp emit_event(type, measurements, metadata, opts) do
    :telemetry.execute(
      [:assistant, :sync, :write_coordinator, type],
      measurements,
      metadata
    )

    case Keyword.get(opts, :event_hook) do
      hook when is_function(hook, 1) ->
        hook.(%{type: type, measurements: measurements, metadata: metadata})

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp lease_enforcement_enabled? do
    Application.get_env(:assistant, :google_write_lease_enforcement, false)
  end
end
