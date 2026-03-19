defmodule Assistant.Memory.DecayCoolingWorkerTest do
  use Assistant.DataCase, async: true

  import Assistant.MemoryFixtures
  alias Assistant.Memory.DecayCoolingWorker
  alias Assistant.Schemas.MemoryEntry

  describe "module compilation" do
    test "module is loaded and defines Oban callbacks" do
      assert Code.ensure_loaded?(DecayCoolingWorker)
      assert function_exported?(DecayCoolingWorker, :perform, 1)
      assert function_exported?(DecayCoolingWorker, :new, 1)
    end
  end

  describe "new/1 changeset" do
    test "builds valid Oban job changeset" do
      changeset = DecayCoolingWorker.new(%{})
      assert %Ecto.Changeset{} = changeset
      assert changeset.valid?
    end

    test "job uses maintenance queue" do
      changeset = DecayCoolingWorker.new(%{})
      assert changeset.changes[:queue] == "maintenance"
    end

    test "max attempts is 1 (no retry)" do
      changeset = DecayCoolingWorker.new(%{})
      assert changeset.changes[:max_attempts] == 1
    end
  end

  describe "perform/1 memory decay cooling" do
    test "cools decay_factor toward 1.0 for boosted memories" do
      user = user_fixture()
      entry = memory_fixture!(user, "Boosted memory")

      # Set decay_factor above 1.0 via raw SQL (bypasses changeset 0-1 validation)
      Repo.query!("UPDATE memory_entries SET decay_factor = 1.3 WHERE id = $1", [
        Ecto.UUID.dump!(entry.id)
      ])

      # Run the cooling worker
      assert :ok = DecayCoolingWorker.perform(%Oban.Job{args: %{}})

      # Reload and check: should be 1.0 + (1.3 - 1.0) * 0.9 = 1.27
      reloaded = Repo.get!(MemoryEntry, entry.id)
      decay = Decimal.to_float(reloaded.decay_factor)
      assert_in_delta decay, 1.27, 0.01
    end

    test "does not change decay_factor already at 1.0" do
      user = user_fixture()
      entry = memory_fixture!(user, "Normal memory")

      assert :ok = DecayCoolingWorker.perform(%Oban.Job{args: %{}})

      reloaded = Repo.get!(MemoryEntry, entry.id)
      assert Decimal.equal?(reloaded.decay_factor, Decimal.new("1.00"))
    end

    test "multiple runs asymptotically approach 1.0" do
      user = user_fixture()
      entry = memory_fixture!(user, "Hot memory")

      Repo.query!("UPDATE memory_entries SET decay_factor = 1.5 WHERE id = $1", [
        Ecto.UUID.dump!(entry.id)
      ])

      # Run cooling 3 times
      for _ <- 1..3 do
        DecayCoolingWorker.perform(%Oban.Job{args: %{}})
      end

      reloaded = Repo.get!(MemoryEntry, entry.id)
      decay = Decimal.to_float(reloaded.decay_factor)
      # After 3 rounds: 1.0 + 0.5 * 0.9^3 = 1.0 + 0.5 * 0.729 = 1.3645
      assert decay < 1.5
      assert decay > 1.0
    end
  end
end
