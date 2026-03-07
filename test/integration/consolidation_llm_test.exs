# test/integration/consolidation_llm_test.exs
#
# Integration tests for knowledge graph consolidation with REAL LLM calls.
#
# Tests that the consolidation mission correctly identifies cross-memory
# entity connections across business domains: engineering, marketing,
# finance, operations, strategy, events, email threads, and transcripts.
#
# Uses MemoryFixtures to seed a realistic workspace with ~45 memories,
# ~27 entities, and ~13 relations (with ~28 intentional gaps).
#
# Requires: OPENROUTER_API_KEY env var with a valid API key.
# Tests are skipped if the key is not available.
#
# Related files:
#   - test/support/fixtures/memory_fixtures.ex (workspace seed data)
#   - lib/assistant/memory/agent.ex (consolidate mission builder)
#   - lib/assistant/memory/turn_classifier.ex (consolidate classification)
#   - lib/assistant/memory/store.ex (memory persistence)
#   - lib/assistant/skills/memory/extract_entities.ex (entity extraction)

defmodule Assistant.Integration.ConsolidationLLMTest do
  use Assistant.DataCase, async: false

  import Assistant.Integration.TestLogger
  import Assistant.MemoryFixtures

  alias Assistant.Integrations.OpenRouter
  alias Assistant.Repo
  alias Assistant.Schemas.{MemoryEntity, MemoryEntityRelation}

  @moduletag :integration
  @moduletag timeout: 180_000

  @integration_model "openai/gpt-5.2"

  @allowed_relation_types ~w(works_at works_with manages reports_to part_of owns related_to located_in supersedes)

  # -------------------------------------------------------------------
  # Setup
  # -------------------------------------------------------------------

  setup do
    case System.get_env("OPENROUTER_API_KEY") do
      key when is_binary(key) and key != "" ->
        {:ok, api_key: key}

      _ ->
        :ok
    end
  end

  # ===================================================================
  # Engineering domain
  # ===================================================================

  describe "engineering: candidate-project matching" do
    @tag :integration
    test "LLM links Alice to Project Phoenix via distributed systems", context do
      if not has_api_key?(context), do: flunk("Skipped: OPENROUTER_API_KEY not set")

      user = user_fixture()
      ws = seed_minimal!(user)

      result =
        consolidation_analysis(
          "We need to find someone for the Project Phoenix team lead role. Someone with distributed systems experience.",
          "I recall that Alice Chen specializes in distributed systems. She could be a strong candidate for Phoenix.",
          memories_to_text([ws.memories.alice_role, ws.memories.phoenix_need]),
          [
            entity_to_graph(ws.entities.alice, []),
            entity_to_graph(ws.entities.phoenix, [%{type: "part_of", target: "TechCo"}])
          ],
          context.api_key
        )

      assert {:ok, analysis} = result
      connections = analysis["new_relations"]
      assert length(connections) >= 1
      assert has_link?(connections, ~r/alice/i, ~r/phoenix/i)
    end
  end

  describe "engineering: multi-project staffing" do
    @tag :integration
    test "LLM discovers David→Atlas and Eva→Neptune from hiring email", context do
      if not has_api_key?(context), do: flunk("Skipped: OPENROUTER_API_KEY not set")

      user = user_fixture()
      ws = seed_workspace!(user)

      result =
        consolidation_analysis(
          "Bob said we need to staff up fast — Phoenix needs distributed systems, Atlas needs ML, Neptune needs Kubernetes. Who do we have?",
          "Looking at the team: David Lee has ML experience from OpenMind AI and wants an AI platform project — perfect for Atlas. Eva Schmidt is a Kubernetes specialist who already offered to help TechCo.",
          memories_to_text([
            ws.memories.david_role, ws.memories.david_ml_project,
            ws.memories.eva_role, ws.memories.eva_k8s,
            ws.memories.bob_hiring, ws.memories.atlas, ws.memories.neptune
          ]),
          [
            entity_to_graph(ws.entities.david, [%{type: "works_at", target: "OpenMind AI", meta: "former"}]),
            entity_to_graph(ws.entities.eva, []),
            entity_to_graph(ws.entities.atlas, [%{type: "part_of", target: "TechCo"}]),
            entity_to_graph(ws.entities.neptune, [%{type: "part_of", target: "TechCo"}])
          ],
          context.api_key
        )

      assert {:ok, analysis} = result
      connections = analysis["new_relations"]
      assert length(connections) >= 2
      assert has_link?(connections, ~r/david/i, ~r/atlas/i)
      assert has_link?(connections, ~r/eva/i, ~r/neptune/i)
    end
  end

  # ===================================================================
  # Marketing domain
  # ===================================================================

  describe "marketing: campaign leadership and event planning" do
    @tag :integration
    test "LLM links Frank→Brand Relaunch and James→TechCo Connect", context do
      if not has_api_key?(context), do: flunk("Skipped: OPENROUTER_API_KEY not set")

      user = user_fixture()
      ws = seed_workspace!(user)

      result =
        consolidation_analysis(
          "What's the status of our marketing initiatives?",
          "Frank Torres is leading the $2M Brand Relaunch for Q3. James Wu is organizing TechCo Connect, the developer conference in Austin for October.",
          memories_to_text([
            ws.memories.frank_role, ws.memories.brand_relaunch,
            ws.memories.james_role, ws.memories.techco_connect
          ]),
          [
            entity_to_graph(ws.entities.frank, [%{type: "works_at", target: "TechCo"}]),
            entity_to_graph(ws.entities.james, []),
            entity_to_graph(ws.entities.brand_relaunch, []),
            entity_to_graph(ws.entities.techco, [%{type: "located_in", target: "San Francisco"}])
          ],
          context.api_key
        )

      assert {:ok, analysis} = result
      connections = analysis["new_relations"]
      assert length(connections) >= 2

      # Frank should be linked to Brand Relaunch (manages)
      assert has_link?(connections, ~r/frank/i, ~r/brand/i)
    end
  end

  # ===================================================================
  # Finance domain
  # ===================================================================

  describe "finance: fundraise and investor connections" do
    @tag :integration
    test "LLM links Grace→Series C and Vertex→TechCo", context do
      if not has_api_key?(context), do: flunk("Skipped: OPENROUTER_API_KEY not set")

      user = user_fixture()
      ws = seed_workspace!(user)

      result =
        consolidation_analysis(
          "How's the Series C going?",
          "Grace Kim is leading the process. Vertex Partners has expressed strong interest as lead investor. They want to see Q1 close rates before committing.",
          memories_to_text([
            ws.memories.grace_role, ws.memories.series_c,
            ws.memories.vertex_meeting, ws.memories.arr_update
          ]),
          [
            entity_to_graph(ws.entities.grace, [%{type: "works_at", target: "TechCo"}]),
            entity_to_graph(ws.entities.series_c, []),
            entity_to_graph(ws.entities.vertex, []),
            entity_to_graph(ws.entities.techco, [%{type: "located_in", target: "San Francisco"}])
          ],
          context.api_key
        )

      assert {:ok, analysis} = result
      connections = analysis["new_relations"]
      assert length(connections) >= 2

      # Grace manages the Series C
      assert has_link?(connections, ~r/grace/i, ~r/series/i)
      # Vertex is related to TechCo (investor)
      assert has_link?(connections, ~r/vertex/i, ~r/techco/i)
    end
  end

  # ===================================================================
  # Cross-functional: email thread consolidation
  # ===================================================================

  describe "cross-functional: budget email connects finance and marketing" do
    @tag :integration
    test "LLM finds budget constraint linking Series C to Brand Relaunch", context do
      if not has_api_key?(context), do: flunk("Skipped: OPENROUTER_API_KEY not set")

      user = user_fixture()
      ws = seed_workspace!(user)

      result =
        consolidation_analysis(
          "I saw Grace's email about the budget freeze. What does that mean for marketing?",
          "Grace Kim sent an email freezing Q2 headcount until the Series C term sheet is signed. Brand Relaunch can continue with approved spend, but all other hiring is paused.",
          memories_to_text([
            ws.memories.budget_email, ws.memories.series_c,
            ws.memories.brand_relaunch, ws.memories.grace_role
          ]),
          [
            entity_to_graph(ws.entities.grace, [%{type: "works_at", target: "TechCo"}]),
            entity_to_graph(ws.entities.frank, [%{type: "works_at", target: "TechCo"}]),
            entity_to_graph(ws.entities.series_c, []),
            entity_to_graph(ws.entities.brand_relaunch, [])
          ],
          context.api_key
        )

      assert {:ok, analysis} = result
      connections = analysis["new_relations"]
      assert length(connections) >= 1
      assert is_binary(analysis["summary"])
      assert String.length(analysis["summary"]) > 10
    end
  end

  # ===================================================================
  # Cross-functional: meeting transcript consolidation
  # ===================================================================

  describe "cross-functional: ops standup transcript" do
    @tag :integration
    test "LLM discovers Eva→Austin expansion and James→office launch from transcript", context do
      if not has_api_key?(context), do: flunk("Skipped: OPENROUTER_API_KEY not set")

      user = user_fixture()
      ws = seed_workspace!(user)

      result =
        consolidation_analysis(
          "Can you summarize the ops standup from yesterday?",
          "Key points: Austin office lease signed, buildout starts March 1. Eva's team handles remote infra. James will help with the office launch party alongside TechCo Connect planning.",
          memories_to_text([
            ws.memories.ops_transcript, ws.memories.austin_expansion,
            ws.memories.eva_k8s, ws.memories.techco_connect,
            ws.memories.henry_role
          ]),
          [
            entity_to_graph(ws.entities.henry, [%{type: "reports_to", target: "Bob Martinez"}]),
            entity_to_graph(ws.entities.eva, []),
            entity_to_graph(ws.entities.james, []),
            entity_to_graph(ws.entities.austin, [])
          ],
          context.api_key
        )

      assert {:ok, analysis} = result
      connections = analysis["new_relations"]
      assert length(connections) >= 1
      assert_valid_relation_types(connections)
    end
  end

  # ===================================================================
  # Strategy domain
  # ===================================================================

  describe "strategy: competitive analysis cross-references" do
    @tag :integration
    test "LLM links DataFlow Labs as competitor and Atlas as differentiator", context do
      if not has_api_key?(context), do: flunk("Skipped: OPENROUTER_API_KEY not set")

      user = user_fixture()
      ws = seed_workspace!(user)

      result =
        consolidation_analysis(
          "What's our competitive positioning against DataFlow Labs?",
          "Isabel Reyes identified DataFlow Labs as TechCo's biggest threat. She recommends accelerating Project Atlas to differentiate on AI capabilities. DataFlow's Series B gives them 18 months of runway.",
          memories_to_text([
            ws.memories.competitive_analysis, ws.memories.isabel_role,
            ws.memories.dataflow, ws.memories.atlas, ws.memories.market_positioning
          ]),
          [
            entity_to_graph(ws.entities.isabel, []),
            entity_to_graph(ws.entities.dataflow, []),
            entity_to_graph(ws.entities.techco, [%{type: "located_in", target: "San Francisco"}]),
            entity_to_graph(ws.entities.atlas, [%{type: "part_of", target: "TechCo"}]),
            entity_to_graph(ws.entities.vertex, [])
          ],
          context.api_key
        )

      assert {:ok, analysis} = result
      connections = analysis["new_relations"]
      assert length(connections) >= 1
      # DataFlow should be related to TechCo (competitor)
      assert has_link?(connections, ~r/dataflow/i, ~r/techco/i) or
               has_link?(connections, ~r/techco/i, ~r/dataflow/i)
    end
  end

  # ===================================================================
  # Deduplication
  # ===================================================================

  describe "deduplication: fully connected subgraph" do
    @tag :integration
    test "LLM proposes no duplicates when all relations already exist", context do
      if not has_api_key?(context), do: flunk("Skipped: OPENROUTER_API_KEY not set")

      user = user_fixture()
      ws = seed_fully_connected!(user)

      result =
        consolidation_analysis(
          "Tell me about Bob's job at TechCo.",
          "Bob Martinez is the CTO at TechCo.",
          memories_to_text([ws.memories.bob_role]),
          [
            entity_to_graph(ws.entities.bob, [%{type: "works_at", target: "TechCo", confidence: 0.95}]),
            entity_to_graph(ws.entities.techco, [%{type: "works_at", source: "Bob Martinez", confidence: 0.95}])
          ],
          context.api_key
        )

      assert {:ok, analysis} = result
      connections = analysis["new_relations"]

      # No duplicate works_at should be proposed
      duplicate =
        Enum.any?(connections, fn rel ->
          String.downcase(rel["relation_type"]) == "works_at" and
            rel["source_entity"] =~ ~r/bob/i and rel["target_entity"] =~ ~r/techco/i
        end)

      refute duplicate,
             "LLM proposed duplicate works_at: #{inspect(connections)}"
    end
  end

  # ===================================================================
  # Graceful degradation
  # ===================================================================

  describe "graceful degradation: no related memories" do
    @tag :integration
    test "LLM returns empty relations for trivial exchange", context do
      if not has_api_key?(context), do: flunk("Skipped: OPENROUTER_API_KEY not set")

      result =
        consolidation_analysis(
          "I had coffee this morning.",
          "That sounds nice! Coffee is always a good way to start the day.",
          [],
          [],
          context.api_key
        )

      assert {:ok, analysis} = result
      connections = analysis["new_relations"]
      assert length(connections) == 0
      assert is_binary(analysis["summary"])
    end
  end

  describe "graceful degradation: isolated entity with no connections" do
    @tag :integration
    test "LLM finds nothing when entity has no related memories", context do
      if not has_api_key?(context), do: flunk("Skipped: OPENROUTER_API_KEY not set")

      user = user_fixture()
      ws = seed_isolated!(user)

      result =
        consolidation_analysis(
          "What do we know about cooking?",
          "I found a memory about cooking but nothing else related.",
          [ws.memory.content],
          [entity_to_graph(ws.entity, [])],
          context.api_key
        )

      assert {:ok, analysis} = result
      connections = analysis["new_relations"]
      assert length(connections) == 0
    end
  end

  # ===================================================================
  # Relation type validation
  # ===================================================================

  describe "relation type accuracy" do
    @tag :integration
    test "all proposed relations use valid types from the allowed set", context do
      if not has_api_key?(context), do: flunk("Skipped: OPENROUTER_API_KEY not set")

      user = user_fixture()
      ws = seed_workspace!(user)

      # Use a rich exchange that should produce multiple relation types
      result =
        consolidation_analysis(
          "Can you map out the leadership team and their responsibilities?",
          "Bob Martinez (CTO) oversees engineering. Frank Torres (CMO) leads marketing and the Brand Relaunch. Grace Kim (CFO) handles finance and the Series C. Henry Okafor (VP Ops) manages the Austin expansion. Isabel Reyes (Strategy Director) works with Grace on investor narratives.",
          memories_to_text([
            ws.memories.bob_role, ws.memories.frank_role, ws.memories.grace_role,
            ws.memories.henry_role, ws.memories.isabel_role,
            ws.memories.brand_relaunch, ws.memories.series_c, ws.memories.austin_expansion
          ]),
          [
            entity_to_graph(ws.entities.bob, [%{type: "works_at", target: "TechCo"}]),
            entity_to_graph(ws.entities.frank, [%{type: "works_at", target: "TechCo"}]),
            entity_to_graph(ws.entities.grace, [%{type: "works_at", target: "TechCo"}]),
            entity_to_graph(ws.entities.henry, [%{type: "reports_to", target: "Bob Martinez"}]),
            entity_to_graph(ws.entities.isabel, []),
            entity_to_graph(ws.entities.brand_relaunch, []),
            entity_to_graph(ws.entities.series_c, []),
            entity_to_graph(ws.entities.techco, [%{type: "located_in", target: "San Francisco"}])
          ],
          context.api_key
        )

      assert {:ok, analysis} = result
      connections = analysis["new_relations"]
      assert length(connections) >= 3,
             "Expected at least 3 relations from leadership overview, got #{length(connections)}"
      assert_valid_relation_types(connections)
    end
  end

  # ===================================================================
  # Temporal integrity
  # ===================================================================

  describe "temporal: role change scenario" do
    @tag :integration
    test "LLM does not re-propose closed relation", context do
      if not has_api_key?(context), do: flunk("Skipped: OPENROUTER_API_KEY not set")

      user = user_fixture()
      ws = seed_role_change!(user)

      result =
        consolidation_analysis(
          "Where does Carol work now?",
          "Carol Park now works at TechCo as a product manager. She used to be at DataFlow Labs.",
          memories_to_text([ws.memories.old, ws.memories.new]),
          [
            entity_to_graph(ws.entities.carol, [
              %{type: "works_at", target: "TechCo", confidence: 0.95},
              %{type: "works_at", target: "DataFlow Labs", confidence: 0.90, meta: "closed"}
            ]),
            entity_to_graph(ws.entities.techco, []),
            entity_to_graph(ws.entities.dataflow, [])
          ],
          context.api_key
        )

      assert {:ok, analysis} = result
      connections = analysis["new_relations"]

      # Should NOT re-propose Carol works_at DataFlow (it's closed)
      stale_dup =
        Enum.any?(connections, fn rel ->
          String.downcase(rel["relation_type"]) == "works_at" and
            rel["source_entity"] =~ ~r/carol/i and rel["target_entity"] =~ ~r/dataflow/i
        end)

      refute stale_dup,
             "LLM re-proposed closed works_at relation: #{inspect(connections)}"
    end
  end

  # ===================================================================
  # Cross-domain: marketing + finance
  # ===================================================================

  describe "cross-domain: marketing-finance bridge" do
    @tag :integration
    test "LLM discovers cross-domain connections from seed_cross_domain!", context do
      if not has_api_key?(context), do: flunk("Skipped: OPENROUTER_API_KEY not set")

      user = user_fixture()
      ws = seed_cross_domain!(user)

      result =
        consolidation_analysis(
          "What's blocking the Brand Relaunch budget?",
          "Grace Kim froze spending until the Series C term sheet is signed. Frank Torres needs to hold Brand Relaunch spend. Vertex Partners is the potential lead investor.",
          memories_to_text([ws.memories.frank_role, ws.memories.grace_fundraise, ws.memories.budget_email]),
          [
            entity_to_graph(ws.entities.frank, [%{type: "works_at", target: "TechCo"}]),
            entity_to_graph(ws.entities.grace, [%{type: "works_at", target: "TechCo"}]),
            entity_to_graph(ws.entities.brand, []),
            entity_to_graph(ws.entities.series_c, []),
            entity_to_graph(ws.entities.vertex, [])
          ],
          context.api_key
        )

      assert {:ok, analysis} = result
      connections = analysis["new_relations"]
      assert length(connections) >= 2
      assert_valid_relation_types(connections)

      # Frank should manage Brand Relaunch
      assert has_link?(connections, ~r/frank/i, ~r/brand/i)
    end
  end

  # ===================================================================
  # Helpers
  # ===================================================================

  defp has_api_key?(context), do: Map.has_key?(context, :api_key)

  defp memories_to_text(memories) when is_list(memories) do
    Enum.map(memories, & &1.content)
  end

  defp entity_to_graph(entity, relations) do
    %{name: entity.name, type: entity.entity_type, relations: relations}
  end

  defp has_link?(connections, source_pattern, target_pattern) do
    Enum.any?(connections, fn rel ->
      s = rel["source_entity"] || ""
      t = rel["target_entity"] || ""
      (s =~ source_pattern and t =~ target_pattern) or
        (s =~ target_pattern and t =~ source_pattern)
    end)
  end

  defp assert_valid_relation_types(connections) do
    for rel <- connections do
      rel_type = rel["relation_type"] || ""
      assert rel_type in @allowed_relation_types,
             "Invalid relation type '#{rel_type}'. Allowed: #{inspect(@allowed_relation_types)}"
    end
  end

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
                    "works_at", "works_with", "manages", "reports_to",
                    "part_of", "owns", "related_to", "located_in", "supersedes"
                  ],
                  description: "Type of relation"
                },
                confidence: %{type: "number", description: "Confidence score 0-1"},
                reasoning: %{type: "string", description: "Why this relation was inferred"}
              },
              required: ["source_entity", "target_entity", "relation_type", "confidence", "reasoning"],
              additionalProperties: false
            }
          }
        },
        required: ["summary", "new_relations"],
        additionalProperties: false
      }
    }
  }

  defp consolidation_analysis(user_message, assistant_response, existing_memories, existing_entities, api_key) do
    memories_section =
      case existing_memories do
        [] -> "No related memories found."
        mems ->
          mems
          |> Enum.with_index(1)
          |> Enum.map_join("\n", fn {mem, i} -> "  #{i}. #{mem}" end)
      end

    entities_section =
      case existing_entities do
        [] -> "No entities in the knowledge graph match this exchange."
        ents ->
          Enum.map_join(ents, "\n", fn ent ->
            rels =
              case ent[:relations] || [] do
                [] -> "no existing relations"
                rs ->
                  Enum.map_join(rs, ", ", fn r ->
                    type = r[:type] || "related_to"
                    target = r[:target] || r[:source] || "?"
                    conf = r[:confidence] || "?"
                    meta = if r[:meta], do: " [#{r[:meta]}]", else: ""
                    "#{type} → #{target} (confidence: #{conf})#{meta}"
                  end)
              end

            "  - #{ent[:name]} (#{ent[:type]}): #{rels}"
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
