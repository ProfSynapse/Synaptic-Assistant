defmodule Assistant.Memory.DecayCoolingWorker do
  @moduledoc false
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  import Ecto.Query
  alias Assistant.Repo
  alias Assistant.Schemas.MemoryEntry

  @cooling_rate 0.9

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    cool_memory_decay_factors()
    cool_folder_activation_boosts()
    :ok
  end

  defp cool_memory_decay_factors do
    from(me in MemoryEntry,
      where: not is_nil(me.decay_factor) and me.decay_factor != 1.0
    )
    |> Repo.update_all(
      set: [
        decay_factor: fragment(
          "1.0 + (COALESCE(decay_factor, 1.0) - 1.0) * ?",
          ^@cooling_rate
        )
      ]
    )
  end

  defp cool_folder_activation_boosts do
    # Only run if the document_folders table exists (Phase 3d)
    if table_exists?("document_folders") do
      from(df in "document_folders",
        where: fragment("activation_boost != 1.0")
      )
      |> Repo.update_all(
        set: [
          activation_boost: fragment(
            "1.0 + (COALESCE(activation_boost, 1.0) - 1.0) * ?",
            ^@cooling_rate
          )
        ]
      )
    end
  end

  defp table_exists?(table_name) do
    query = "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = $1)"
    case Repo.query(query, [table_name]) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end
end
