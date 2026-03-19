# test/assistant/embeddings/real_embeddings_integration_test.exs
#
# Integration tests that require the embedding model running locally
# (Nx.Serving backed by gte-small via Bumblebee). Tagged @moduletag :integration
# so they are excluded from `mix test` by default.
#
# Run with: mix test --include integration test/assistant/embeddings/real_embeddings_integration_test.exs
#
# Prerequisites:
#   - Embeddings enabled: Application.put_env(:assistant, :embeddings, enabled: true)
#   - Nx.Serving started with the Assistant.Embeddings name
#   - Model downloaded (gte-small)

defmodule Assistant.Embeddings.RealEmbeddingsIntegrationTest do
  use Assistant.DataCase, async: false

  @moduletag :integration

  import Assistant.MemoryFixtures
  alias Assistant.Embeddings
  alias Assistant.Embeddings.UnifiedSearch
  alias Assistant.Memory.Activation
  alias Assistant.Schemas.MemoryEntry

  setup do
    original = Application.get_env(:assistant, :embeddings, [])
    Application.put_env(:assistant, :embeddings, enabled: true)
    on_exit(fn -> Application.put_env(:assistant, :embeddings, original) end)
    :ok
  end

  # ---------------------------------------------------------------
  # Embeddings.generate/1 — basic embedding quality
  # ---------------------------------------------------------------

  describe "generate/1 with real model" do
    test "returns 384-dimensional embedding" do
      {:ok, embedding} = Embeddings.generate("Elixir is a functional programming language")
      assert length(embedding) == 384
      assert Enum.all?(embedding, &is_float/1)
    end

    test "embedding is L2-normalized (unit vector)" do
      {:ok, embedding} = Embeddings.generate("Testing normalization")
      norm = :math.sqrt(Enum.reduce(embedding, 0.0, fn x, acc -> acc + x * x end))
      assert_in_delta norm, 1.0, 0.01
    end

    test "similar texts produce similar embeddings" do
      {:ok, emb_a} = Embeddings.generate("The cat sat on the mat")
      {:ok, emb_b} = Embeddings.generate("A cat was sitting on a mat")
      {:ok, emb_c} = Embeddings.generate("Quantum physics and string theory")

      sim_ab = cosine_sim(emb_a, emb_b)
      sim_ac = cosine_sim(emb_a, emb_c)

      # Similar sentences should have higher similarity than unrelated ones
      assert sim_ab > sim_ac
      assert sim_ab > 0.8, "Expected similar texts to have cosine_sim > 0.8, got #{sim_ab}"
      assert sim_ac < 0.5, "Expected unrelated texts to have cosine_sim < 0.5, got #{sim_ac}"
    end

    test "truncates long input without error" do
      long_text = String.duplicate("word ", 1000)
      assert {:ok, embedding} = Embeddings.generate(long_text)
      assert length(embedding) == 384
    end
  end

  # ---------------------------------------------------------------
  # generate_batch/1 — batch embedding
  # ---------------------------------------------------------------

  describe "generate_batch/1 with real model" do
    test "returns one embedding per text" do
      texts = ["Hello world", "Elixir macros", "GenServer callbacks"]
      {:ok, embeddings} = Embeddings.generate_batch(texts)
      assert length(embeddings) == 3
      Enum.each(embeddings, fn emb -> assert length(emb) == 384 end)
    end

    test "batch embeddings match individual embeddings" do
      texts = ["First sentence", "Second sentence"]
      {:ok, batch} = Embeddings.generate_batch(texts)
      {:ok, single_0} = Embeddings.generate("First sentence")
      {:ok, single_1} = Embeddings.generate("Second sentence")

      # Batch and individual should produce nearly identical embeddings
      assert_in_delta cosine_sim(Enum.at(batch, 0), single_0), 1.0, 0.01
      assert_in_delta cosine_sim(Enum.at(batch, 1), single_1), 1.0, 0.01
    end
  end

  # ---------------------------------------------------------------
  # Activation.spread/2 with real embeddings
  # ---------------------------------------------------------------

  describe "activation spread with real embeddings" do
    test "similar memories get boosted, dissimilar do not" do
      user = user_fixture()

      # Create memories with real embeddings
      source = create_embedded_memory!(user, "Elixir pattern matching is powerful")
      similar = create_embedded_memory!(user, "Pattern matching in Elixir simplifies code")
      dissimilar = create_embedded_memory!(user, "The weather forecast predicts rain tomorrow")

      Activation.spread(user.id, [%{id: source.id, embedding: source.embedding}])

      similar_decay = Decimal.to_float(Repo.get!(MemoryEntry, similar.id).decay_factor)
      dissimilar_decay = Decimal.to_float(Repo.get!(MemoryEntry, dissimilar.id).decay_factor)

      # Similar memory should be boosted more than dissimilar
      assert similar_decay > dissimilar_decay
    end
  end

  # ---------------------------------------------------------------
  # UnifiedSearch.search/2 end-to-end with real embeddings
  # ---------------------------------------------------------------

  describe "search/2 end-to-end with real embeddings" do
    test "finds relevant memories via FTS (arcana still stubbed)" do
      user = user_fixture()
      _entry = memory_fixture!(user, "Elixir supervisors restart child processes on failure")

      # Even with embeddings enabled, arcana is stubbed so docs return []
      # but FTS memories still flow through the parallel path + RRF merge
      results = UnifiedSearch.search(user.id, "Elixir supervisor restart")

      assert length(results) >= 1
      assert hd(results).type == :memory
    end
  end

  # ---------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------

  defp cosine_sim(a, b) do
    Enum.zip_reduce(a, b, 0.0, fn x, y, acc -> acc + x * y end)
  end

  defp create_embedded_memory!(user, content) do
    entry = memory_fixture!(user, content)
    {:ok, embedding} = Embeddings.generate(content)

    entry
    |> Ecto.Changeset.change(%{embedding: embedding})
    |> Repo.update!()
  end
end
