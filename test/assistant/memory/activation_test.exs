defmodule Assistant.Memory.ActivationTest do
  use Assistant.DataCase, async: true

  import Assistant.MemoryFixtures
  alias Assistant.Memory.Activation
  alias Assistant.Schemas.MemoryEntry

  # Generate a deterministic L2-normalized 384-dim embedding
  defp fake_embedding(seed) do
    :rand.seed(:exsss, {seed, seed, seed})
    raw = for _ <- 1..384, do: :rand.uniform() * 2 - 1
    norm = :math.sqrt(Enum.reduce(raw, 0.0, fn x, acc -> acc + x * x end))
    Enum.map(raw, &(&1 / norm))
  end

  # Insert a memory entry with an embedding via Ecto.Changeset.change
  defp memory_with_embedding!(user, content, seed) do
    entry = memory_fixture!(user, content)
    embedding = fake_embedding(seed)

    entry
    |> Ecto.Changeset.change(%{embedding: embedding})
    |> Repo.update!()
  end

  describe "spread/2 with empty or invalid input" do
    test "returns :ok for empty list" do
      user = user_fixture()
      assert :ok = Activation.spread(user.id, [])
    end

    test "returns :ok for non-list input" do
      assert :ok = Activation.spread("some-id", "not a list")
    end

    test "returns :ok for nil input" do
      assert :ok = Activation.spread("some-id", nil)
    end
  end

  describe "spread/2 with embeddings" do
    test "does not modify retrieved entries themselves" do
      user = user_fixture()
      entry = memory_with_embedding!(user, "Retrieved memory", 1)
      _neighbor = memory_with_embedding!(user, "Neighbor memory", 2)

      Activation.spread(user.id, [%{id: entry.id, embedding: entry.embedding}])

      reloaded = Repo.get!(MemoryEntry, entry.id)
      # Retrieved entry decay_factor should stay at default (1.00)
      assert Decimal.equal?(reloaded.decay_factor, Decimal.new("1.00"))
    end

    test "skips entries without embeddings" do
      user = user_fixture()
      entry_with = memory_with_embedding!(user, "Has embedding", 1)
      entry_without = memory_fixture!(user, "No embedding")

      Activation.spread(user.id, [%{id: entry_with.id, embedding: entry_with.embedding}])

      reloaded_without = Repo.get!(MemoryEntry, entry_without.id)
      assert Decimal.equal?(reloaded_without.decay_factor, Decimal.new("1.00"))
    end

    test "handles %{entry: %{...}} wrapper pattern for retrieved entries" do
      user = user_fixture()
      entry = memory_with_embedding!(user, "Entry A", 10)
      _neighbor = memory_with_embedding!(user, "Neighbor B", 11)

      # Should not raise — uses the %{entry: entry} pattern to extract id and embedding
      assert :ok = Activation.spread(user.id, [%{entry: entry}])
    end

    test "handles entries with nil embedding gracefully" do
      user = user_fixture()
      entry = memory_fixture!(user, "No embedding entry")

      # nil embedding is skipped by the `if embedding` guard in spread
      assert :ok = Activation.spread(user.id, [%{id: entry.id, embedding: nil}])
    end

    test "caps at max_decay_factor (1.5)" do
      user = user_fixture()

      # Create a retrieved entry and a neighbor with similar embeddings
      retrieved = memory_with_embedding!(user, "Retrieved for cap test", 50)
      neighbor = memory_with_embedding!(user, "Neighbor for cap test", 51)

      # Set neighbor's decay_factor above 1.0 via raw SQL (bypasses changeset validation)
      Repo.query!("UPDATE memory_entries SET decay_factor = 1.48 WHERE id = $1", [
        Ecto.UUID.dump!(neighbor.id)
      ])

      # Spread activation — boost formula: LEAST(1.5, 1.48 + 0.05 * sim)
      # Even with max cosine sim of 1.0, boost would be 1.48 + 0.05 = 1.53, capped to 1.5
      Activation.spread(user.id, [%{id: retrieved.id, embedding: retrieved.embedding}])

      reloaded = Repo.get!(MemoryEntry, neighbor.id)
      # decay_factor should not exceed 1.5
      assert Decimal.to_float(reloaded.decay_factor) <= 1.5
    end
  end

  describe "spread/2 boost math precision" do
    test "boost formula is LEAST(1.5, decay_factor + 0.05 * cosine_similarity)" do
      user = user_fixture()

      # Use identical embeddings (seed 50 for both) → cosine similarity ≈ 1.0
      retrieved = memory_with_embedding!(user, "Source memory", 50)
      neighbor = memory_with_embedding!(user, "Identical neighbor", 50)

      Activation.spread(user.id, [%{id: retrieved.id, embedding: retrieved.embedding}])

      reloaded = Repo.get!(MemoryEntry, neighbor.id)
      decay = Decimal.to_float(reloaded.decay_factor)
      # Formula: LEAST(1.5, 1.0 + 0.05 * ~1.0) ≈ 1.05
      # Cosine sim of identical vectors = 1.0 (dot product of L2-normalized vectors)
      assert_in_delta decay, 1.05, 0.01
    end

    test "boost proportional to cosine similarity (dissimilar gets less)" do
      user = user_fixture()

      retrieved = memory_with_embedding!(user, "Source A", 300)
      similar_neighbor = memory_with_embedding!(user, "Similar B", 301)
      dissimilar_neighbor = memory_with_embedding!(user, "Different C", 999)

      Activation.spread(user.id, [%{id: retrieved.id, embedding: retrieved.embedding}])

      similar_decay = Decimal.to_float(Repo.get!(MemoryEntry, similar_neighbor.id).decay_factor)
      dissimilar_decay =
        Decimal.to_float(Repo.get!(MemoryEntry, dissimilar_neighbor.id).decay_factor)

      # Similar neighbor should get higher boost than dissimilar one
      # (or dissimilar may not be boosted at all if similarity < 0.6 threshold)
      assert similar_decay >= dissimilar_decay
    end

    test "neighbors below min_similarity threshold (0.6) are not boosted" do
      user = user_fixture()

      # Create a retrieved entry with one embedding
      retrieved = memory_with_embedding!(user, "Source X", 1)

      # Create a neighbor with a very different embedding (high seed distance)
      # Random embeddings from very different seeds tend to have low cosine similarity
      far_neighbor = memory_with_embedding!(user, "Far away neighbor", 99999)

      Activation.spread(user.id, [%{id: retrieved.id, embedding: retrieved.embedding}])

      reloaded = Repo.get!(MemoryEntry, far_neighbor.id)
      far_decay = Decimal.to_float(reloaded.decay_factor)

      # If similarity < 0.6, neighbor should not be boosted (stays at 1.0)
      # Note: random vectors in high dimensions tend to cluster near 0 cosine sim
      assert_in_delta far_decay, 1.0, 0.01
    end
  end

  describe "spread/2 isolation" do
    test "does not affect other users' memories" do
      user1 = user_fixture()
      user2 = user_fixture()
      entry1 = memory_with_embedding!(user1, "User 1 memory", 100)
      entry2 = memory_with_embedding!(user2, "User 2 memory", 101)

      Activation.spread(user1.id, [%{id: entry1.id, embedding: entry1.embedding}])

      reloaded2 = Repo.get!(MemoryEntry, entry2.id)
      assert Decimal.equal?(reloaded2.decay_factor, Decimal.new("1.00"))
    end
  end
end
