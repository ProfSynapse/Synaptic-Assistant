defmodule Assistant.Memory.DecayCoolingWorker do
  @moduledoc false
  use Oban.Worker, queue: :maintenance, max_attempts: 3

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
      where: not is_nil(me.decay_factor) and me.decay_factor != 1.0,
      update: [
        set: [
          decay_factor:
            fragment(
              "1.0 + (COALESCE(decay_factor, 1.0) - 1.0) * ?",
              ^@cooling_rate
            )
        ]
      ]
    )
    |> Repo.update_all([])
  end

  defp cool_folder_activation_boosts do
    from(df in "document_folders",
      where: fragment("activation_boost != 1.0"),
      update: [
        set: [
          activation_boost:
            fragment(
              "1.0 + (COALESCE(activation_boost, 1.0) - 1.0) * ?",
              ^@cooling_rate
            )
        ]
      ]
    )
    |> Repo.update_all([])
  end
end
