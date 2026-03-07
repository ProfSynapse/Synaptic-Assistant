# test/integration/consolidation_llm_test.exs
#
# Integration tests for knowledge graph consolidation with REAL LLM calls.
#
# Tests that the consolidation mission correctly identifies cross-memory
# entity connections and produces appropriate entity extraction calls.
# Seeds real memories and entities in the DB, then asks the LLM to find
# connections the way the Memory Agent would during a :consolidate mission.
#
# Requires: OPENROUTER_API_KEY env var with a valid API key.
# Tests are skipped if the key is not available.
#
# Related files:
#   - lib/assistant/memory/agent.ex (consolidate mission builder)
#   - lib/assistant/memory/turn_classifier.ex (consolidate classification)
#   - lib/assistant/memory/store.ex (memory persistence)
#   - lib/assistant/memory/search.ex (memory retrieval)
#   - lib/assistant/skills/memory/extract_entities.ex (entity extraction handler)

defmodule Assistant.Integration.ConsolidationLLMTest do
  use Assistant.DataCase, async: false

  import Assistant.Integration.TestLogger

  alias Assistant.Integrations.OpenRouter
  alias Assistant.Memory.Store
  alias Assistant.Repo
  alias Assistant.Schemas.{MemoryEntity, MemoryEntityRelation, User}

  @moduletag :integration
  @moduletag timeout: 120_000

  @integration_model "openai/gpt-5.2"

  # -------------------------------------------------------------------
  # Setup
  # -------------------------------------------------------------------

  setup do
    case System.get_env("OPENROUTER_API_KEY") do
      key when is_binary(key) and key != "" ->
        user = create_test_user!()
        {:ok, api_key: key, user: user}

      _ ->
        :ok
    end
  end

  defp create_test_user! do
    %User{}
    |> User.changeset(%{
      external_id: "consolidation-test-#{System.unique_integer([:positive])}",
      channel: "test",
      display_name: "Consolidation Test User"
    })
    |> Repo.insert!()
  end

  # -------------------------------------------------------------------
  # Scenario 1: Cross-memory connection discovery
  #
  # Two memories exist about different entities. A new exchange reveals
  # a connection between them. The LLM should identify the relation.
  # -------------------------------------------------------------------

  describe "cross-memory connection discovery" do
    @tag :integration
    test "LLM identifies relation between entities from separate memories", context do
      if not has_api_key?(context), do: flunk("Skipped: OPENROUTER_API_KEY not set")

      user = context.user

      # Seed Memory A: Alice is an engineer
      {:ok, _mem_a} =
        Store.create_memory_entry(%{
          content: "Alice Chen is a senior backend engineer specializing in distributed systems.",
          category: "fact",
          tags: ["person", "engineer"],
          source_type: "conversation",
          user_id: user.id
        })

      # Seed Memory B: Project Phoenix needs distributed systems expertise
      {:ok, _mem_b} =
        Store.create_memory_entry(%{
          content:
            "Project Phoenix is a new microservices migration that requires distributed systems expertise. The team lead position is open.",
          category: "fact",
          tags: ["project", "hiring"],
          source_type: "conversation",
          user_id: user.id
        })

      # Seed the entities
      alice =
        %MemoryEntity{}
        |> MemoryEntity.changeset(%{
          name: "Alice Chen",
          entity_type: "person",
          metadata: %{"role" => "senior backend engineer"},
          user_id: user.id
        })
        |> Repo.insert!()

      phoenix =
        %MemoryEntity{}
        |> MemoryEntity.changeset(%{
          name: "Project Phoenix",
          entity_type: "project",
          metadata: %{"status" => "staffing"},
          user_id: user.id
        })
        |> Repo.insert!()

      # The new exchange that should trigger consolidation
      user_message =
        "We need to find someone for the Project Phoenix team lead role. Someone with distributed systems experience."

      assistant_response =
        "I recall that Alice Chen is a senior backend engineer specializing in distributed systems. She could be a strong candidate for the Project Phoenix team lead position."

      # Ask the LLM to analyze cross-memory connections
      result =
        consolidation_analysis(
          user_message,
          assistant_response,
          [
            "Alice Chen is a senior backend engineer specializing in distributed systems.",
            "Project Phoenix is a new microservices migration that requires distributed systems expertise. The team lead position is open."
          ],
          [
            %{name: "Alice Chen", type: "person", relations: []},
            %{name: "Project Phoenix", type: "project", relations: []}
          ],
          context.api_key
        )

      assert {:ok, analysis} = result
      assert is_map(analysis)

      # The LLM should identify at least one new relation connecting the entities
      connections = analysis["new_relations"] || analysis["relations"] || []
      assert is_list(connections)
      assert length(connections) >= 1

      # At least one relation should link Alice to Project Phoenix
      has_cross_link =
        Enum.any?(connections, fn rel ->
          source = rel["source"] || rel["from_entity"] || rel["source_entity"] || ""
          target = rel["target"] || rel["to_entity"] || rel["target_entity"] || ""

          (source =~ ~r/alice/i and target =~ ~r/phoenix/i) or
            (source =~ ~r/phoenix/i and target =~ ~r/alice/i)
        end)

      assert has_cross_link,
             "Expected a relation connecting Alice Chen to Project Phoenix, got: #{inspect(connections)}"

      # Verify the entities still exist (consolidation shouldn't delete)
      assert Repo.get(MemoryEntity, alice.id)
      assert Repo.get(MemoryEntity, phoenix.id)
    end
  end

  # -------------------------------------------------------------------
  # Scenario 2: Empty search results — graceful degradation
  #
  # The LLM is given a consolidation mission but the search returns
  # no related memories. It should report "nothing to consolidate"
  # rather than hallucinating connections.
  # -------------------------------------------------------------------

  describe "consolidation with no related memories" do
    @tag :integration
    test "LLM reports no connections when search returns empty results", context do
      if not has_api_key?(context), do: flunk("Skipped: OPENROUTER_API_KEY not set")

      # Exchange about an entity with no prior memories or entities
      user_message = "I had coffee this morning."
      assistant_response = "That sounds nice! Coffee is always a good way to start the day."

      result =
        consolidation_analysis(
          user_message,
          assistant_response,
          [],
          [],
          context.api_key
        )

      assert {:ok, analysis} = result
      assert is_map(analysis)

      # Should report no connections found
      connections = analysis["new_relations"] || analysis["relations"] || []
      assert is_list(connections)
      assert length(connections) == 0

      # Should explicitly indicate nothing to consolidate
      summary = analysis["summary"] || analysis["reasoning"] || ""
      assert is_binary(summary)
    end
  end

  # -------------------------------------------------------------------
  # Scenario 3: Existing relation — deduplication
  #
  # An entity relation already exists. The LLM should recognize this
  # and not propose a duplicate.
  # -------------------------------------------------------------------

  describe "consolidation respects existing relations" do
    @tag :integration
    test "LLM does not propose duplicate relations", context do
      if not has_api_key?(context), do: flunk("Skipped: OPENROUTER_API_KEY not set")

      user = context.user

      # Seed memories
      {:ok, _mem} =
        Store.create_memory_entry(%{
          content: "Bob Smith works at Acme Corp as CTO.",
          category: "fact",
          tags: ["person", "organization"],
          source_type: "conversation",
          user_id: user.id
        })

      # Seed entities and an existing relation
      bob =
        %MemoryEntity{}
        |> MemoryEntity.changeset(%{
          name: "Bob Smith",
          entity_type: "person",
          metadata: %{"role" => "CTO"},
          user_id: user.id
        })
        |> Repo.insert!()

      acme =
        %MemoryEntity{}
        |> MemoryEntity.changeset(%{
          name: "Acme Corp",
          entity_type: "organization",
          metadata: %{},
          user_id: user.id
        })
        |> Repo.insert!()

      # Existing relation: Bob works_at Acme
      %MemoryEntityRelation{}
      |> MemoryEntityRelation.changeset(%{
        relation_type: "works_at",
        source_entity_id: bob.id,
        target_entity_id: acme.id,
        confidence: Decimal.new("0.95")
      })
      |> Repo.insert!()

      user_message = "Tell me about Bob's job at Acme."
      assistant_response = "Bob Smith is the CTO at Acme Corp."

      result =
        consolidation_analysis(
          user_message,
          assistant_response,
          ["Bob Smith works at Acme Corp as CTO."],
          [
            %{
              name: "Bob Smith",
              type: "person",
              relations: [%{type: "works_at", target: "Acme Corp", confidence: 0.95}]
            },
            %{
              name: "Acme Corp",
              type: "organization",
              relations: [%{type: "works_at", source: "Bob Smith", confidence: 0.95}]
            }
          ],
          context.api_key
        )

      assert {:ok, analysis} = result
      assert is_map(analysis)

      # Should report zero new relations (Bob→Acme already captured)
      connections = analysis["new_relations"] || analysis["relations"] || []
      assert is_list(connections)

      # If any relations proposed, they should NOT be a duplicate works_at
      duplicate =
        Enum.any?(connections, fn rel ->
          type = rel["relation_type"] || rel["type"] || ""
          source = rel["source"] || rel["from_entity"] || rel["source_entity"] || ""
          target = rel["target"] || rel["to_entity"] || rel["target_entity"] || ""

          String.downcase(type) == "works_at" and
            source =~ ~r/bob/i and target =~ ~r/acme/i
        end)

      refute duplicate,
             "LLM proposed duplicate works_at relation that already exists: #{inspect(connections)}"
    end
  end

  # -------------------------------------------------------------------
  # Scenario 4: Multi-entity consolidation
  #
  # Multiple entities exist across several memories. A new exchange
  # references several of them, revealing a web of connections.
  # -------------------------------------------------------------------

  describe "multi-entity consolidation" do
    @tag :integration
    test "LLM discovers multiple relations from rich context", context do
      if not has_api_key?(context), do: flunk("Skipped: OPENROUTER_API_KEY not set")

      user = context.user

      # Seed a rich context
      {:ok, _} =
        Store.create_memory_entry(%{
          content: "Sarah Park is a product manager at TechCo.",
          category: "fact",
          tags: ["person", "organization"],
          source_type: "conversation",
          user_id: user.id
        })

      {:ok, _} =
        Store.create_memory_entry(%{
          content: "Project Atlas is TechCo's new AI platform initiative.",
          category: "fact",
          tags: ["project", "organization"],
          source_type: "conversation",
          user_id: user.id
        })

      {:ok, _} =
        Store.create_memory_entry(%{
          content: "David Lee is a machine learning engineer looking for new projects.",
          category: "fact",
          tags: ["person", "engineer"],
          source_type: "conversation",
          user_id: user.id
        })

      # Seed entities (no relations yet)
      for {name, type} <- [
            {"Sarah Park", "person"},
            {"TechCo", "organization"},
            {"Project Atlas", "project"},
            {"David Lee", "person"}
          ] do
        %MemoryEntity{}
        |> MemoryEntity.changeset(%{name: name, entity_type: type, user_id: user.id})
        |> Repo.insert!()
      end

      user_message = """
      Sarah just told me she's been assigned to lead Project Atlas at TechCo.
      She's looking for an ML engineer to join. David Lee might be perfect — he's
      been wanting a new project.
      """

      assistant_response = """
      That's a great match! Sarah Park is leading Project Atlas at TechCo, and
      David Lee has the ML expertise they need. I can see several connections here.
      """

      result =
        consolidation_analysis(
          user_message,
          assistant_response,
          [
            "Sarah Park is a product manager at TechCo.",
            "Project Atlas is TechCo's new AI platform initiative.",
            "David Lee is a machine learning engineer looking for new projects."
          ],
          [
            %{name: "Sarah Park", type: "person", relations: []},
            %{name: "TechCo", type: "organization", relations: []},
            %{name: "Project Atlas", type: "project", relations: []},
            %{name: "David Lee", type: "person", relations: []}
          ],
          context.api_key
        )

      assert {:ok, analysis} = result
      connections = analysis["new_relations"] || analysis["relations"] || []
      assert is_list(connections)

      # Should find at least 2 relations (e.g., Sarah leads Atlas, Atlas part_of TechCo)
      assert length(connections) >= 2,
             "Expected at least 2 new relations from rich context, got #{length(connections)}: #{inspect(connections)}"

      # Verify entity names appear in the relations
      all_entities_referenced =
        connections
        |> Enum.flat_map(fn rel ->
          source = rel["source"] || rel["from_entity"] || rel["source_entity"] || ""
          target = rel["target"] || rel["to_entity"] || rel["target_entity"] || ""
          [String.downcase(source), String.downcase(target)]
        end)
        |> Enum.join(" ")

      # At least Sarah and Project Atlas should be connected
      assert all_entities_referenced =~ ~r/sarah/i or all_entities_referenced =~ ~r/atlas/i,
             "Expected Sarah or Atlas in relations, got: #{inspect(connections)}"
    end
  end

  # -------------------------------------------------------------------
  # Scenario 5: Relation type accuracy
  #
  # Verify the LLM uses appropriate relation types from the allowed set
  # rather than inventing custom ones.
  # -------------------------------------------------------------------

  describe "relation type accuracy" do
    @tag :integration
    test "LLM uses valid relation types from the allowed set", context do
      if not has_api_key?(context), do: flunk("Skipped: OPENROUTER_API_KEY not set")

      user = context.user

      {:ok, _} =
        Store.create_memory_entry(%{
          content: "Maria Garcia manages the engineering team at DataFlow Inc.",
          category: "fact",
          tags: ["person", "organization"],
          source_type: "conversation",
          user_id: user.id
        })

      {:ok, _} =
        Store.create_memory_entry(%{
          content: "James Wilson just joined DataFlow Inc as a junior engineer.",
          category: "fact",
          tags: ["person", "organization"],
          source_type: "conversation",
          user_id: user.id
        })

      for {name, type} <- [
            {"Maria Garcia", "person"},
            {"James Wilson", "person"},
            {"DataFlow Inc", "organization"}
          ] do
        %MemoryEntity{}
        |> MemoryEntity.changeset(%{name: name, entity_type: type, user_id: user.id})
        |> Repo.insert!()
      end

      user_message = "Maria is now managing James on the engineering team at DataFlow."

      assistant_response =
        "Noted — Maria Garcia manages James Wilson at DataFlow Inc."

      result =
        consolidation_analysis(
          user_message,
          assistant_response,
          [
            "Maria Garcia manages the engineering team at DataFlow Inc.",
            "James Wilson just joined DataFlow Inc as a junior engineer."
          ],
          [
            %{name: "Maria Garcia", type: "person", relations: []},
            %{name: "James Wilson", type: "person", relations: []},
            %{name: "DataFlow Inc", type: "organization", relations: []}
          ],
          context.api_key
        )

      assert {:ok, analysis} = result
      connections = analysis["new_relations"] || analysis["relations"] || []

      @allowed_relation_types ~w(works_at works_with manages reports_to part_of owns related_to located_in supersedes)

      for rel <- connections do
        rel_type = rel["relation_type"] || rel["type"] || ""

        assert String.downcase(rel_type) in @allowed_relation_types,
               "Invalid relation type '#{rel_type}'. Must be one of: #{inspect(@allowed_relation_types)}"
      end
    end
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp has_api_key?(context), do: Map.has_key?(context, :api_key)

  @consolidation_response_format %{
    type: "json_schema",
    json_schema: %{
      name: "consolidation_analysis",
      strict: true,
      schema: %{
        type: "object",
        properties: %{
          summary: %{
            type: "string",
            description: "Brief explanation of what connections were found or why none exist"
          },
          new_relations: %{
            type: "array",
            description: "List of newly discovered relations between existing entities",
            items: %{
              type: "object",
              properties: %{
                source_entity: %{type: "string", description: "Name of the source entity"},
                target_entity: %{type: "string", description: "Name of the target entity"},
                relation_type: %{
                  type: "string",
                  enum: [
                    "works_at",
                    "works_with",
                    "manages",
                    "reports_to",
                    "part_of",
                    "owns",
                    "related_to",
                    "located_in",
                    "supersedes"
                  ],
                  description: "Type of relation"
                },
                confidence: %{
                  type: "number",
                  description: "Confidence score 0-1"
                },
                reasoning: %{
                  type: "string",
                  description: "Why this relation was inferred"
                }
              },
              required: [
                "source_entity",
                "target_entity",
                "relation_type",
                "confidence",
                "reasoning"
              ],
              additionalProperties: false
            }
          }
        },
        required: ["summary", "new_relations"],
        additionalProperties: false
      }
    }
  }

  @doc """
  Asks the LLM to analyze cross-memory connections, simulating what the
  Memory Agent does during a :consolidate mission.

  Provides the LLM with:
  - The triggering user/assistant exchange
  - Existing memories (simulating search_memories results)
  - Existing entity graph (simulating query_entity_graph results)

  Returns `{:ok, analysis_map}` or `{:error, reason}`.
  """
  defp consolidation_analysis(
         user_message,
         assistant_response,
         existing_memories,
         existing_entities,
         api_key
       ) do
    memories_section =
      case existing_memories do
        [] ->
          "No related memories found."

        memories ->
          memories
          |> Enum.with_index(1)
          |> Enum.map_join("\n", fn {mem, i} -> "  #{i}. #{mem}" end)
      end

    entities_section =
      case existing_entities do
        [] ->
          "No entities in the knowledge graph match this exchange."

        entities ->
          Enum.map_join(entities, "\n", fn ent ->
            relations =
              case ent[:relations] || ent["relations"] || [] do
                [] ->
                  "no existing relations"

                rels ->
                  Enum.map_join(rels, ", ", fn r ->
                    type = r[:type] || r["type"] || "related_to"
                    target = r[:target] || r["target"] || r[:source] || r["source"] || "?"
                    confidence = r[:confidence] || r["confidence"] || "?"
                    "#{type} → #{target} (confidence: #{confidence})"
                  end)
              end

            "  - #{ent[:name] || ent["name"]} (#{ent[:type] || ent["type"]}): #{relations}"
          end)
      end

    prompt = """
    You are a knowledge graph consolidation agent. Your job is to find NEW
    connections between existing entities based on the conversation exchange
    and existing memories below. Do NOT re-save memories or create new entities.
    Only identify new relations between entities that already exist.

    ## Triggering Exchange

    User: #{user_message}
    Assistant: #{assistant_response}

    ## Existing Memories (from search)

    #{memories_section}

    ## Existing Entity Graph (from query)

    #{entities_section}

    ## Instructions

    1. Analyze the exchange and existing memories for implicit connections.
    2. Look for relations that emerge from connecting facts across memories.
    3. Only propose relations between entities listed above.
    4. Use ONLY these relation types: works_at, works_with, manages, reports_to,
       part_of, owns, related_to, located_in, supersedes.
    5. Do NOT propose relations that already exist in the entity graph above.
    6. If no new connections are found, return an empty relations array with
       a summary explaining why.
    7. Set confidence based on how directly the evidence supports the relation.
    """

    messages = [%{role: "user", content: prompt}]

    opts = [
      model: @integration_model,
      temperature: 0.0,
      max_tokens: 2000,
      response_format: @consolidation_response_format,
      api_key: api_key
    ]

    log_request("consolidation_analysis", %{
      model: @integration_model,
      messages: messages,
      response_format: @consolidation_response_format,
      temperature: 0.0,
      max_tokens: 2000
    })

    {elapsed, api_result} =
      timed(fn -> OpenRouter.chat_completion(messages, opts) end)

    case api_result do
      {:ok, %{content: content}} when is_binary(content) ->
        log_response("consolidation_analysis", {:ok, %{content: content}})

        cleaned =
          content
          |> String.trim()
          |> String.replace(~r/^```json\s*/, "")
          |> String.replace(~r/\s*```$/, "")
          |> String.trim()

        case Jason.decode(cleaned) do
          {:ok, parsed} ->
            log_pass("consolidation_analysis", elapsed)
            {:ok, parsed}

          {:error, decode_error} ->
            log_fail("consolidation_analysis", {:json_decode_failed, decode_error})
            {:error, {:json_decode_failed, decode_error}}
        end

      {:ok, %{content: nil}} ->
        log_fail("consolidation_analysis", :empty_content)
        {:error, :empty_content}

      {:error, reason} ->
        log_response("consolidation_analysis", {:error, reason})
        log_fail("consolidation_analysis", reason)
        {:error, {:llm_call_failed, reason}}
    end
  end
end
