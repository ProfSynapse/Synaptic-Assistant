defmodule Assistant.MemoryFixtures do
  @moduledoc """
  Test helpers for seeding the memory subsystem with realistic synthetic data.

  Provides a rich cross-domain workspace spanning engineering, marketing,
  finance, operations, strategy, events, email threads, and meeting
  transcripts. Designed for memory agent tests, consolidation integration
  tests, and any test that needs a populated knowledge graph.

  ## Usage

      import Assistant.MemoryFixtures

      setup do
        user = user_fixture()
        workspace = seed_workspace!(user)
        %{user: user, ws: workspace}
      end

  The workspace map contains all seeded records keyed by short names:

      workspace.entities.alice      # => %MemoryEntity{name: "Alice Chen", ...}
      workspace.memories.alice_role # => %MemoryEntry{content: "Alice Chen is...", ...}
      workspace.relations.bob_at_techco # => %MemoryEntityRelation{...}

  ## Building custom scenarios

  Use the lower-level helpers to seed exactly what a test needs:

      entity = entity_fixture!(user, "Bob", "person", %{"role" => "CTO"})
      memory = memory_fixture!(user, "Bob is the CTO.", tags: ["person", "org"])
      relation = relation_fixture!(entity_a, entity_b, "works_at")
      mention = mention_fixture!(entity, memory)
  """

  alias Assistant.Repo

  alias Assistant.Schemas.{
    Conversation,
    MemoryEntity,
    MemoryEntityMention,
    MemoryEntityRelation,
    MemoryEntry,
    User
  }

  # -------------------------------------------------------------------
  # Low-level fixtures
  # -------------------------------------------------------------------

  @doc "Creates a test user with a unique external_id."
  def user_fixture(attrs \\ %{}) do
    defaults = %{
      external_id: "mem-test-#{System.unique_integer([:positive])}",
      channel: "test",
      display_name: attrs[:display_name] || "Test User"
    }

    %User{}
    |> User.changeset(Map.merge(defaults, Map.drop(attrs, [:display_name])))
    |> Repo.insert!()
  end

  @doc "Creates a conversation for the given user."
  def conversation_fixture!(user) do
    %Conversation{}
    |> Conversation.changeset(%{
      user_id: user.id,
      channel: "test",
      started_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  @doc """
  Creates a memory entry for the given user.

  Options:
    - :category (default "fact")
    - :tags (default [])
    - :source_type (default "conversation")
    - :importance (default 0.50)
    - :conversation_id (optional)
  """
  def memory_fixture!(user, content, opts \\ []) do
    attrs = %{
      content: content,
      category: Keyword.get(opts, :category, "fact"),
      tags: Keyword.get(opts, :tags, []),
      source_type: Keyword.get(opts, :source_type, "conversation"),
      importance: Keyword.get(opts, :importance, Decimal.new("0.50")),
      user_id: user.id,
      source_conversation_id: Keyword.get(opts, :conversation_id)
    }

    %MemoryEntry{}
    |> MemoryEntry.changeset(attrs)
    |> Repo.insert!()
  end

  @doc "Creates an entity for the given user."
  def entity_fixture!(user, name, entity_type, metadata \\ %{}) do
    %MemoryEntity{}
    |> MemoryEntity.changeset(%{
      name: name,
      entity_type: entity_type,
      metadata: metadata,
      user_id: user.id
    })
    |> Repo.insert!()
  end

  @doc """
  Creates a directed relation between two entities.

  Options:
    - :confidence (default 0.90)
    - :metadata (default %{})
    - :source_memory_entry_id (optional provenance)
  """
  def relation_fixture!(source, target, relation_type, opts \\ []) do
    %MemoryEntityRelation{}
    |> MemoryEntityRelation.changeset(%{
      relation_type: relation_type,
      source_entity_id: source.id,
      target_entity_id: target.id,
      confidence: Keyword.get(opts, :confidence, Decimal.new("0.90")),
      metadata: Keyword.get(opts, :metadata, %{}),
      source_memory_entry_id: Keyword.get(opts, :source_memory_entry_id)
    })
    |> Repo.insert!()
  end

  @doc "Links an entity to a memory entry (mention)."
  def mention_fixture!(entity, memory_entry) do
    %MemoryEntityMention{}
    |> MemoryEntityMention.changeset(%{
      entity_id: entity.id,
      memory_entry_id: memory_entry.id
    })
    |> Repo.insert!()
  end

  # -------------------------------------------------------------------
  # Full workspace seed — cross-domain business scenario
  #
  # Domains: Engineering, Marketing, Finance, Operations, Strategy,
  #          Events, Email threads, Meeting transcripts
  #
  # People (10):
  #   Alice Chen (Sr Backend Eng), Bob Martinez (CTO),
  #   Carol Park (Product Manager), David Lee (ML Engineer),
  #   Eva Schmidt (DevOps Lead), Frank Torres (CMO),
  #   Grace Kim (CFO), Henry Okafor (VP Operations),
  #   Isabel Reyes (Strategy Director), James Wu (Event Manager)
  #
  # Orgs (4):  TechCo, DataFlow Labs, OpenMind AI, Vertex Partners
  # Projects (5): Phoenix, Atlas, Neptune, Brand Relaunch, Series C
  # Concepts (5): distributed systems, ML, Kubernetes, CAC, ARR
  # Locations (3): San Francisco, Berlin, Austin
  #
  # Memories (~45): roles, facts, emails, transcripts, events, decisions
  # Relations (~12): partially wired — many gaps for consolidation
  # Mentions (~80): entity-to-memory links
  # -------------------------------------------------------------------

  @doc """
  Seeds a full cross-domain workspace. Returns a map of all records.

  Many entity connections are intentionally omitted so tests can verify
  the consolidation agent discovers them.
  """
  def seed_workspace!(user) do
    #
    # ======== ENTITIES ========
    #

    # -- People --
    alice =
      entity_fixture!(user, "Alice Chen", "person", %{
        "role" => "senior backend engineer",
        "dept" => "engineering",
        "specialty" => "distributed systems"
      })

    bob =
      entity_fixture!(user, "Bob Martinez", "person", %{"role" => "CTO", "dept" => "engineering"})

    carol =
      entity_fixture!(user, "Carol Park", "person", %{
        "role" => "product manager",
        "dept" => "product"
      })

    david =
      entity_fixture!(user, "David Lee", "person", %{
        "role" => "ML engineer",
        "dept" => "engineering",
        "looking_for" => "new project"
      })

    eva =
      entity_fixture!(user, "Eva Schmidt", "person", %{
        "role" => "DevOps lead",
        "dept" => "engineering",
        "location" => "Berlin"
      })

    frank =
      entity_fixture!(user, "Frank Torres", "person", %{"role" => "CMO", "dept" => "marketing"})

    grace = entity_fixture!(user, "Grace Kim", "person", %{"role" => "CFO", "dept" => "finance"})

    henry =
      entity_fixture!(user, "Henry Okafor", "person", %{
        "role" => "VP Operations",
        "dept" => "operations"
      })

    isabel =
      entity_fixture!(user, "Isabel Reyes", "person", %{
        "role" => "Strategy Director",
        "dept" => "strategy"
      })

    james =
      entity_fixture!(user, "James Wu", "person", %{
        "role" => "Event Manager",
        "dept" => "marketing"
      })

    # -- Organizations --
    techco =
      entity_fixture!(user, "TechCo", "organization", %{
        "industry" => "enterprise SaaS",
        "hq" => "San Francisco",
        "headcount" => "200"
      })

    dataflow =
      entity_fixture!(user, "DataFlow Labs", "organization", %{
        "industry" => "data infrastructure",
        "stage" => "Series B"
      })

    openmind =
      entity_fixture!(user, "OpenMind AI", "organization", %{
        "industry" => "AI research",
        "hq" => "Berlin"
      })

    vertex =
      entity_fixture!(user, "Vertex Partners", "organization", %{
        "type" => "VC firm",
        "focus" => "enterprise SaaS"
      })

    # -- Projects --
    phoenix =
      entity_fixture!(user, "Project Phoenix", "project", %{
        "type" => "microservices migration",
        "dept" => "engineering",
        "needs" => "distributed systems"
      })

    atlas =
      entity_fixture!(user, "Project Atlas", "project", %{
        "type" => "AI platform",
        "dept" => "engineering",
        "status" => "staffing"
      })

    neptune =
      entity_fixture!(user, "Project Neptune", "project", %{
        "type" => "Kubernetes infrastructure",
        "dept" => "engineering",
        "status" => "planning"
      })

    brand_relaunch =
      entity_fixture!(user, "Brand Relaunch", "project", %{
        "type" => "marketing campaign",
        "dept" => "marketing",
        "budget" => "$2M"
      })

    series_c =
      entity_fixture!(user, "Series C", "project", %{
        "type" => "fundraise",
        "dept" => "finance",
        "target" => "$50M"
      })

    # -- Concepts --
    distrib = entity_fixture!(user, "distributed systems", "concept", %{})
    ml = entity_fixture!(user, "machine learning", "concept", %{})
    k8s = entity_fixture!(user, "Kubernetes", "concept", %{})
    cac = entity_fixture!(user, "customer acquisition cost", "concept", %{"abbrev" => "CAC"})
    arr = entity_fixture!(user, "annual recurring revenue", "concept", %{"abbrev" => "ARR"})

    # -- Locations --
    sf = entity_fixture!(user, "San Francisco", "location", %{})
    berlin = entity_fixture!(user, "Berlin", "location", %{})
    austin = entity_fixture!(user, "Austin", "location", %{})

    entities = %{
      alice: alice,
      bob: bob,
      carol: carol,
      david: david,
      eva: eva,
      frank: frank,
      grace: grace,
      henry: henry,
      isabel: isabel,
      james: james,
      techco: techco,
      dataflow: dataflow,
      openmind: openmind,
      vertex: vertex,
      phoenix: phoenix,
      atlas: atlas,
      neptune: neptune,
      brand_relaunch: brand_relaunch,
      series_c: series_c,
      distrib: distrib,
      ml: ml,
      k8s: k8s,
      cac: cac,
      arr: arr,
      sf: sf,
      berlin: berlin,
      austin: austin
    }

    #
    # ======== MEMORIES ========
    #

    # ---------- Engineering ----------

    m_alice_role =
      memory_fixture!(
        user,
        "Alice Chen is a senior backend engineer specializing in distributed systems. She has 8 years of experience building large-scale microservices.",
        tags: ["person", "engineering", "distributed systems"],
        importance: Decimal.new("0.80")
      )

    m_bob_role =
      memory_fixture!(
        user,
        "Bob Martinez is the CTO of TechCo. He oversees all engineering teams and has been pushing for a microservices migration.",
        tags: ["person", "engineering", "leadership"],
        importance: Decimal.new("0.85")
      )

    m_carol_role =
      memory_fixture!(
        user,
        "Carol Park is a product manager at TechCo. She manages the AI platform roadmap and reports to Bob Martinez.",
        tags: ["person", "product", "leadership"],
        importance: Decimal.new("0.75")
      )

    m_david_role =
      memory_fixture!(
        user,
        "David Lee is a machine learning engineer currently between projects. He's looking for a team that needs ML expertise. Previously worked at OpenMind AI.",
        tags: ["person", "engineering", "machine learning"],
        importance: Decimal.new("0.70")
      )

    m_eva_role =
      memory_fixture!(
        user,
        "Eva Schmidt is a DevOps lead based in Berlin. She specializes in Kubernetes infrastructure and has set up clusters for multiple companies.",
        tags: ["person", "engineering", "kubernetes", "berlin"],
        importance: Decimal.new("0.75")
      )

    m_phoenix =
      memory_fixture!(
        user,
        "Project Phoenix is TechCo's microservices migration initiative. It requires distributed systems expertise and the team lead position is still open.",
        tags: ["project", "engineering", "hiring"],
        importance: Decimal.new("0.85")
      )

    m_atlas =
      memory_fixture!(
        user,
        "Project Atlas is TechCo's new AI platform. Carol Park is defining the roadmap. They need ML engineers to build the inference pipeline.",
        tags: ["project", "engineering", "ai", "hiring"],
        importance: Decimal.new("0.80")
      )

    m_neptune =
      memory_fixture!(
        user,
        "Project Neptune is a planned Kubernetes infrastructure overhaul. It will modernize TechCo's deployment pipeline. No team assigned yet.",
        tags: ["project", "engineering", "kubernetes"],
        importance: Decimal.new("0.70")
      )

    m_alice_interest =
      memory_fixture!(
        user,
        "Alice Chen mentioned she's interested in leading a microservices project. She thinks her distributed systems background would be a good fit.",
        tags: ["person", "career", "distributed systems"],
        importance: Decimal.new("0.75")
      )

    m_david_ml_project =
      memory_fixture!(
        user,
        "David Lee said he'd love to work on an AI platform. He has experience building inference pipelines from his time at OpenMind AI.",
        tags: ["person", "career", "machine learning"],
        importance: Decimal.new("0.70")
      )

    m_eva_k8s =
      memory_fixture!(
        user,
        "Eva Schmidt has been consulting on Kubernetes deployments remotely from Berlin. She mentioned she could help TechCo with their infrastructure.",
        tags: ["person", "kubernetes", "consulting"],
        importance: Decimal.new("0.65")
      )

    m_bob_hiring =
      memory_fixture!(
        user,
        "Bob Martinez said TechCo needs to hire aggressively for three projects: Phoenix (distributed systems), Atlas (ML), and Neptune (Kubernetes). He wants internal referrals first.",
        tags: ["person", "hiring", "engineering"],
        importance: Decimal.new("0.80")
      )

    # ---------- Marketing ----------

    m_frank_role =
      memory_fixture!(
        user,
        "Frank Torres is the CMO of TechCo. He joined six months ago from a consumer tech company and is driving a complete brand overhaul.",
        tags: ["person", "marketing", "leadership"],
        importance: Decimal.new("0.80")
      )

    m_brand_relaunch =
      memory_fixture!(
        user,
        "The Brand Relaunch is a $2M marketing campaign planned for Q3 2026. Frank Torres is leading it. The goal is to reposition TechCo from 'legacy enterprise' to 'modern AI-native platform'.",
        tags: ["project", "marketing", "budget"],
        importance: Decimal.new("0.85")
      )

    m_james_role =
      memory_fixture!(
        user,
        "James Wu is the Event Manager at TechCo. He reports to Frank Torres and is organizing TechCo's first developer conference, 'TechCo Connect', planned for October 2026 in Austin.",
        tags: ["person", "marketing", "events"],
        importance: Decimal.new("0.75")
      )

    m_techco_connect =
      memory_fixture!(
        user,
        "TechCo Connect is a developer conference planned for October 15-17, 2026 in Austin, TX. Expected 500 attendees. James Wu is the lead organizer. Budget: $350K from marketing.",
        tags: ["event", "marketing", "austin"],
        category: "event",
        importance: Decimal.new("0.80")
      )

    m_marketing_email =
      memory_fixture!(
        user,
        "Email from Frank Torres to the leadership team (2026-02-20): 'The Brand Relaunch campaign needs engineering input on the new product demos. Bob, can Alice or someone from Phoenix record a 5-min demo? Carol, need Atlas roadmap slides by March 1. —Frank'",
        tags: ["email", "marketing", "engineering", "cross-functional"],
        category: "email",
        importance: Decimal.new("0.75")
      )

    m_cac_metric =
      memory_fixture!(
        user,
        "Frank Torres reported that TechCo's customer acquisition cost (CAC) dropped 18% after the website redesign. He attributes this to improved messaging and the new case studies page.",
        tags: ["marketing", "metric", "cac"],
        importance: Decimal.new("0.70")
      )

    # ---------- Finance ----------

    m_grace_role =
      memory_fixture!(
        user,
        "Grace Kim is the CFO of TechCo. She manages financial planning, fundraising, and investor relations. She's been at TechCo for 4 years.",
        tags: ["person", "finance", "leadership"],
        importance: Decimal.new("0.85")
      )

    m_series_c =
      memory_fixture!(
        user,
        "TechCo is planning a Series C raise targeting $50M at a $400M pre-money valuation. Grace Kim is leading the process. Vertex Partners has expressed strong interest as lead investor.",
        tags: ["project", "finance", "fundraise"],
        importance: Decimal.new("0.90")
      )

    m_arr_update =
      memory_fixture!(
        user,
        "TechCo's ARR hit $28M in January 2026, up from $21M a year ago. Grace Kim presented these numbers at the board meeting. Net revenue retention is 118%.",
        tags: ["finance", "metric", "arr"],
        importance: Decimal.new("0.85")
      )

    m_budget_email =
      memory_fixture!(
        user,
        "Email from Grace Kim to Bob Martinez and Frank Torres (2026-02-22): 'Q2 budget freeze on new headcount until Series C term sheet is signed. Phoenix and Brand Relaunch can continue with approved spend. All other hiring paused. —Grace'",
        tags: ["email", "finance", "hiring", "budget"],
        category: "email",
        importance: Decimal.new("0.85")
      )

    m_vertex_meeting =
      memory_fixture!(
        user,
        "Meeting with Vertex Partners on 2026-02-18: Grace Kim and Isabel Reyes presented the growth strategy. Vertex is impressed with ARR trajectory. They want to see Q1 close rates before committing. Follow-up scheduled for April.",
        tags: ["meeting", "finance", "strategy", "fundraise"],
        category: "meeting_note",
        importance: Decimal.new("0.90")
      )

    # ---------- Operations ----------

    m_henry_role =
      memory_fixture!(
        user,
        "Henry Okafor is the VP of Operations at TechCo. He manages vendor relationships, office logistics, and the Austin expansion. He reports directly to Bob Martinez.",
        tags: ["person", "operations", "leadership"],
        importance: Decimal.new("0.75")
      )

    m_austin_expansion =
      memory_fixture!(
        user,
        "TechCo is opening a second office in Austin, TX. Henry Okafor is leading the buildout. Target opening: August 2026. Initial capacity: 50 seats for the operations and customer success teams.",
        tags: ["operations", "austin", "expansion"],
        importance: Decimal.new("0.75")
      )

    m_vendor_review =
      memory_fixture!(
        user,
        "Henry Okafor completed the annual vendor review. Key findings: AWS costs up 22% due to Phoenix migration staging environments. He recommends reserved instances and asked Eva Schmidt to optimize the Kubernetes cluster sizing.",
        tags: ["operations", "finance", "engineering"],
        importance: Decimal.new("0.70")
      )

    m_ops_transcript =
      memory_fixture!(
        user,
        "Operations standup transcript (2026-02-24): Henry: 'Austin office lease signed, buildout starts March 1. Need IT setup plan from Eva's team.' Bob: 'Eva can handle remote infra but we need boots on the ground for physical setup.' Henry: 'James, can your events team help with the office launch party?' James: 'Sure, I'll add it to the TechCo Connect planning timeline.'",
        tags: ["transcript", "operations", "engineering", "events"],
        category: "transcript",
        importance: Decimal.new("0.70")
      )

    # ---------- Strategy ----------

    m_isabel_role =
      memory_fixture!(
        user,
        "Isabel Reyes is the Strategy Director at TechCo. She leads competitive analysis, market positioning, and the long-term product vision. She works closely with Grace Kim on investor narratives.",
        tags: ["person", "strategy", "leadership"],
        importance: Decimal.new("0.80")
      )

    m_competitive_analysis =
      memory_fixture!(
        user,
        "Isabel Reyes completed a competitive analysis: DataFlow Labs is TechCo's biggest threat in the data pipeline space. Their Series B gives them 18 months of runway. Isabel recommends accelerating Project Atlas to differentiate on AI capabilities.",
        tags: ["strategy", "competitive", "ai"],
        importance: Decimal.new("0.85")
      )

    m_strategy_offsite =
      memory_fixture!(
        user,
        "Leadership offsite agenda (2026-03-15 in Napa): Day 1 — Isabel presents 3-year roadmap. Day 2 — Grace covers fundraise timeline. Day 3 — Frank + James present brand + TechCo Connect plan. Bob wants Alice to demo Phoenix progress.",
        tags: ["event", "strategy", "leadership"],
        category: "event",
        importance: Decimal.new("0.80")
      )

    m_market_positioning =
      memory_fixture!(
        user,
        "Isabel Reyes proposed a new positioning: 'TechCo — the AI-native enterprise platform.' This aligns with Frank's Brand Relaunch messaging and Carol's Atlas roadmap. Bob approved it at the February leadership meeting.",
        tags: ["strategy", "marketing", "product"],
        importance: Decimal.new("0.80")
      )

    # ---------- Cross-functional / Meetings ----------

    m_leadership_meeting =
      memory_fixture!(
        user,
        "Leadership meeting transcript (2026-02-15): Attendees: Bob, Frank, Grace, Henry, Isabel. Decisions: (1) Prioritize Phoenix over Neptune — Neptune delayed to Q4. (2) Atlas timeline moved to Q3 per Carol's request. (3) Brand Relaunch greenlit for Q3 with $2M budget. (4) Series C process to start March 1.",
        tags: ["meeting", "decision", "leadership"],
        category: "meeting_note",
        importance: Decimal.new("0.95")
      )

    m_allhands_notes =
      memory_fixture!(
        user,
        "All-hands meeting notes (2026-02-28): Bob announced the Austin expansion. Frank previewed the Brand Relaunch creative direction. Grace shared ARR milestone ($28M). Alice demoed the first Phoenix microservice running in production. Henry introduced the new vendor dashboard.",
        tags: ["meeting", "company", "all-hands"],
        category: "meeting_note",
        importance: Decimal.new("0.80")
      )

    m_crossfunc_email =
      memory_fixture!(
        user,
        "Email thread — 'Q3 Planning Alignment' (2026-02-25): Isabel: 'Brand Relaunch and Atlas are both Q3. We need shared messaging.' Frank: 'Agreed — Atlas demos at TechCo Connect would be huge.' Carol: 'Atlas won't be production-ready by October but we can do a preview.' Bob: 'Let's make it happen. David, can you build a demo inference endpoint?'",
        tags: ["email", "cross-functional", "planning"],
        category: "email",
        importance: Decimal.new("0.80")
      )

    # ---------- Org / Location ----------

    m_techco =
      memory_fixture!(
        user,
        "TechCo is an enterprise SaaS company headquartered in San Francisco with about 200 engineers. They are undergoing a major microservices migration and planning an AI platform.",
        tags: ["organization", "san francisco"],
        importance: Decimal.new("0.80")
      )

    m_dataflow =
      memory_fixture!(
        user,
        "DataFlow Labs is a data infrastructure startup. They build real-time streaming pipelines and recently received Series B funding. Isabel Reyes identifies them as TechCo's main competitor.",
        tags: ["organization", "competitive"],
        importance: Decimal.new("0.65")
      )

    m_openmind =
      memory_fixture!(
        user,
        "OpenMind AI is an AI research lab in Berlin. They focus on language models and reinforcement learning. David Lee used to work there before joining the job market.",
        tags: ["organization", "ai", "berlin"],
        importance: Decimal.new("0.70")
      )

    m_vertex =
      memory_fixture!(
        user,
        "Vertex Partners is a VC firm focused on enterprise SaaS. They led DataFlow Labs' Series B and are now in talks with Grace Kim about leading TechCo's Series C.",
        tags: ["organization", "finance", "vc"],
        importance: Decimal.new("0.75")
      )

    # ---------- Preferences / Routine ----------

    m_user_pref_summary =
      memory_fixture!(
        user,
        "The user prefers to receive weekly summaries of project updates rather than daily notifications.",
        tags: ["preference", "notifications"],
        category: "preference",
        importance: Decimal.new("0.60")
      )

    m_user_pref_format =
      memory_fixture!(
        user,
        "The user wants financial metrics presented as a table with MoM change percentages, not raw numbers.",
        tags: ["preference", "finance", "format"],
        category: "preference",
        importance: Decimal.new("0.55")
      )

    m_weather =
      memory_fixture!(
        user,
        "The user asked about the weather in San Francisco. It was 62F and foggy.",
        tags: ["weather", "san francisco"],
        category: "routine",
        importance: Decimal.new("0.10")
      )

    m_greeting =
      memory_fixture!(
        user,
        "The user said good morning and asked how the assistant was doing.",
        tags: ["greeting"],
        category: "routine",
        importance: Decimal.new("0.05")
      )

    memories = %{
      # Engineering
      alice_role: m_alice_role,
      bob_role: m_bob_role,
      carol_role: m_carol_role,
      david_role: m_david_role,
      eva_role: m_eva_role,
      phoenix: m_phoenix,
      atlas: m_atlas,
      neptune: m_neptune,
      alice_interest: m_alice_interest,
      david_ml_project: m_david_ml_project,
      eva_k8s: m_eva_k8s,
      bob_hiring: m_bob_hiring,
      # Marketing
      frank_role: m_frank_role,
      brand_relaunch: m_brand_relaunch,
      james_role: m_james_role,
      techco_connect: m_techco_connect,
      marketing_email: m_marketing_email,
      cac_metric: m_cac_metric,
      # Finance
      grace_role: m_grace_role,
      series_c: m_series_c,
      arr_update: m_arr_update,
      budget_email: m_budget_email,
      vertex_meeting: m_vertex_meeting,
      # Operations
      henry_role: m_henry_role,
      austin_expansion: m_austin_expansion,
      vendor_review: m_vendor_review,
      ops_transcript: m_ops_transcript,
      # Strategy
      isabel_role: m_isabel_role,
      competitive_analysis: m_competitive_analysis,
      strategy_offsite: m_strategy_offsite,
      market_positioning: m_market_positioning,
      # Cross-functional
      leadership_meeting: m_leadership_meeting,
      allhands_notes: m_allhands_notes,
      crossfunc_email: m_crossfunc_email,
      # Org / Location
      techco: m_techco,
      dataflow: m_dataflow,
      openmind: m_openmind,
      vertex: m_vertex,
      # Preferences / Routine
      user_pref_summary: m_user_pref_summary,
      user_pref_format: m_user_pref_format,
      weather: m_weather,
      greeting: m_greeting
    }

    #
    # ======== RELATIONS (partially wired — many gaps) ========
    #

    # Employment — only some wired
    r_bob_at_techco = relation_fixture!(bob, techco, "works_at", confidence: Decimal.new("0.95"))

    r_carol_at_techco =
      relation_fixture!(carol, techco, "works_at", confidence: Decimal.new("0.90"))

    r_frank_at_techco =
      relation_fixture!(frank, techco, "works_at", confidence: Decimal.new("0.90"))

    r_grace_at_techco =
      relation_fixture!(grace, techco, "works_at", confidence: Decimal.new("0.90"))

    r_david_at_openmind =
      relation_fixture!(david, openmind, "works_at",
        confidence: Decimal.new("0.85"),
        metadata: %{"status" => "former"}
      )

    # Org structure — only some reporting lines wired
    r_carol_reports_bob =
      relation_fixture!(carol, bob, "reports_to", confidence: Decimal.new("0.90"))

    r_henry_reports_bob =
      relation_fixture!(henry, bob, "reports_to", confidence: Decimal.new("0.85"))

    # Project ownership
    r_phoenix_at_techco =
      relation_fixture!(phoenix, techco, "part_of", confidence: Decimal.new("0.95"))

    r_atlas_at_techco =
      relation_fixture!(atlas, techco, "part_of", confidence: Decimal.new("0.90"))

    r_neptune_at_techco =
      relation_fixture!(neptune, techco, "part_of", confidence: Decimal.new("0.85"))

    # Concept links — only one wired
    r_phoenix_distrib =
      relation_fixture!(phoenix, distrib, "related_to", confidence: Decimal.new("0.90"))

    # Location
    r_techco_sf = relation_fixture!(techco, sf, "located_in", confidence: Decimal.new("0.95"))

    r_openmind_berlin =
      relation_fixture!(openmind, berlin, "located_in", confidence: Decimal.new("0.95"))

    relations = %{
      bob_at_techco: r_bob_at_techco,
      carol_at_techco: r_carol_at_techco,
      frank_at_techco: r_frank_at_techco,
      grace_at_techco: r_grace_at_techco,
      david_at_openmind: r_david_at_openmind,
      carol_reports_bob: r_carol_reports_bob,
      henry_reports_bob: r_henry_reports_bob,
      phoenix_at_techco: r_phoenix_at_techco,
      atlas_at_techco: r_atlas_at_techco,
      neptune_at_techco: r_neptune_at_techco,
      phoenix_distrib: r_phoenix_distrib,
      techco_sf: r_techco_sf,
      openmind_berlin: r_openmind_berlin
    }

    #
    # ======== ENTITY-MEMORY MENTIONS ========
    #

    # People → memories they appear in
    for m <- [
          m_alice_role,
          m_alice_interest,
          m_marketing_email,
          m_allhands_notes,
          m_strategy_offsite
        ] do
      mention_fixture!(alice, m)
    end

    for m <- [
          m_bob_role,
          m_bob_hiring,
          m_leadership_meeting,
          m_allhands_notes,
          m_budget_email,
          m_crossfunc_email,
          m_ops_transcript
        ] do
      mention_fixture!(bob, m)
    end

    for m <- [m_carol_role, m_atlas, m_leadership_meeting, m_marketing_email, m_crossfunc_email] do
      mention_fixture!(carol, m)
    end

    for m <- [m_david_role, m_david_ml_project, m_crossfunc_email] do
      mention_fixture!(david, m)
    end

    for m <- [m_eva_role, m_eva_k8s, m_vendor_review, m_ops_transcript] do
      mention_fixture!(eva, m)
    end

    for m <- [
          m_frank_role,
          m_brand_relaunch,
          m_marketing_email,
          m_leadership_meeting,
          m_allhands_notes,
          m_crossfunc_email,
          m_strategy_offsite
        ] do
      mention_fixture!(frank, m)
    end

    for m <- [
          m_grace_role,
          m_series_c,
          m_arr_update,
          m_budget_email,
          m_vertex_meeting,
          m_leadership_meeting,
          m_allhands_notes,
          m_strategy_offsite
        ] do
      mention_fixture!(grace, m)
    end

    for m <- [
          m_henry_role,
          m_austin_expansion,
          m_vendor_review,
          m_ops_transcript,
          m_leadership_meeting,
          m_allhands_notes
        ] do
      mention_fixture!(henry, m)
    end

    for m <- [
          m_isabel_role,
          m_competitive_analysis,
          m_strategy_offsite,
          m_market_positioning,
          m_vertex_meeting,
          m_leadership_meeting,
          m_crossfunc_email
        ] do
      mention_fixture!(isabel, m)
    end

    for m <- [m_james_role, m_techco_connect, m_ops_transcript, m_strategy_offsite] do
      mention_fixture!(james, m)
    end

    # Orgs → memories
    for m <- [
          m_techco,
          m_bob_role,
          m_phoenix,
          m_atlas,
          m_neptune,
          m_bob_hiring,
          m_brand_relaunch,
          m_series_c,
          m_arr_update,
          m_austin_expansion,
          m_allhands_notes,
          m_market_positioning,
          m_eva_k8s
        ] do
      mention_fixture!(techco, m)
    end

    for m <- [m_dataflow, m_competitive_analysis] do
      mention_fixture!(dataflow, m)
    end

    for m <- [m_openmind, m_david_role] do
      mention_fixture!(openmind, m)
    end

    for m <- [m_vertex, m_series_c, m_vertex_meeting] do
      mention_fixture!(vertex, m)
    end

    # Projects → memories
    for m <- [
          m_phoenix,
          m_alice_interest,
          m_leadership_meeting,
          m_bob_hiring,
          m_marketing_email,
          m_budget_email,
          m_allhands_notes,
          m_strategy_offsite
        ] do
      mention_fixture!(phoenix, m)
    end

    for m <- [
          m_atlas,
          m_david_ml_project,
          m_leadership_meeting,
          m_competitive_analysis,
          m_crossfunc_email,
          m_market_positioning
        ] do
      mention_fixture!(atlas, m)
    end

    for m <- [m_neptune, m_eva_k8s, m_leadership_meeting] do
      mention_fixture!(neptune, m)
    end

    for m <- [
          m_brand_relaunch,
          m_marketing_email,
          m_leadership_meeting,
          m_market_positioning,
          m_crossfunc_email,
          m_strategy_offsite
        ] do
      mention_fixture!(brand_relaunch, m)
    end

    for m <- [m_series_c, m_vertex_meeting, m_leadership_meeting, m_budget_email] do
      mention_fixture!(series_c, m)
    end

    # Concepts → memories
    for m <- [m_alice_role, m_phoenix, m_alice_interest] do
      mention_fixture!(distrib, m)
    end

    for m <- [m_david_role, m_atlas, m_david_ml_project] do
      mention_fixture!(ml, m)
    end

    for m <- [m_eva_role, m_neptune, m_eva_k8s] do
      mention_fixture!(k8s, m)
    end

    mention_fixture!(cac, m_cac_metric)

    for m <- [m_arr_update, m_vertex_meeting] do
      mention_fixture!(arr, m)
    end

    # Locations → memories
    for m <- [m_techco, m_weather] do
      mention_fixture!(sf, m)
    end

    for m <- [m_eva_role, m_openmind] do
      mention_fixture!(berlin, m)
    end

    for m <- [m_techco_connect, m_austin_expansion, m_ops_transcript] do
      mention_fixture!(austin, m)
    end

    #
    # ======== INTENTIONAL GAPS FOR CONSOLIDATION ========
    #
    # These connections exist in the memories but are NOT wired as relations:
    #
    # Engineering gaps:
    #  1. Alice → TechCo (works_at) — implied but not stated
    #  2. Alice → Project Phoenix (related_to) — she wants to lead it
    #  3. David → Project Atlas (related_to) — he wants AI platform work
    #  4. Eva → Project Neptune (related_to) — she does K8s consulting
    #  5. Eva → Berlin (located_in) — mentioned in role
    #  6. Atlas → machine learning (related_to) — implied
    #  7. Neptune → Kubernetes (related_to) — implied
    #  8. Carol → Project Atlas (manages) — she defines the roadmap
    #  9. Bob → Project Phoenix (manages) — he's pushing the migration
    #
    # Marketing gaps:
    # 10. Frank → Brand Relaunch (manages) — he's leading it
    # 11. James → TechCo Connect (manages) — he's the organizer
    # 12. James reports_to Frank — stated but not wired
    # 13. Brand Relaunch → TechCo (part_of) — not wired
    # 14. TechCo Connect → Austin (located_in) — stated but not wired
    #
    # Finance gaps:
    # 15. Grace → Series C (manages) — she's leading the fundraise
    # 16. Vertex → TechCo (related_to) — investor interest
    # 17. Vertex → DataFlow Labs (related_to) — they led their Series B
    # 18. Series C → TechCo (part_of) — not wired
    #
    # Operations gaps:
    # 19. Henry → TechCo (works_at) — mentioned but not wired
    # 20. Austin expansion → Austin (located_in) — implied
    # 21. Eva → Austin expansion (related_to) — ops transcript asks for her help
    #
    # Strategy gaps:
    # 22. Isabel → TechCo (works_at) — mentioned but not wired
    # 23. Isabel → Grace (works_with) — they co-present to investors
    # 24. DataFlow Labs → TechCo (related_to) — competitor relation
    #
    # Cross-functional gaps:
    # 25. Frank → Bob (works_with) — email thread shows collaboration
    # 26. Isabel → Frank (works_with) — aligned on positioning
    # 27. Alice → TechCo Connect (related_to) — asked to demo at the event
    # 28. David → TechCo Connect (related_to) — asked to build demo endpoint
    #

    %{
      user: user,
      entities: entities,
      memories: memories,
      relations: relations,
      entity_names: Map.new(entities, fn {k, v} -> {k, v.name} end),
      memory_count: map_size(memories),
      entity_count: map_size(entities),
      relation_count: map_size(relations)
    }
  end

  # -------------------------------------------------------------------
  # Scenario-specific seed helpers
  # -------------------------------------------------------------------

  @doc """
  Seeds a minimal scenario: 2 people, 1 org, 1 project with a single
  discoverable gap. Good for focused unit-style tests.
  """
  def seed_minimal!(user) do
    alice = entity_fixture!(user, "Alice Chen", "person", %{"role" => "engineer"})
    techco = entity_fixture!(user, "TechCo", "organization", %{})

    phoenix =
      entity_fixture!(user, "Project Phoenix", "project", %{"needs" => "distributed systems"})

    m1 =
      memory_fixture!(user, "Alice Chen is an engineer specializing in distributed systems.",
        tags: ["person", "engineer"]
      )

    m2 =
      memory_fixture!(user, "Project Phoenix needs a distributed systems lead at TechCo.",
        tags: ["project", "hiring"]
      )

    relation_fixture!(phoenix, techco, "part_of")
    mention_fixture!(alice, m1)
    mention_fixture!(phoenix, m2)
    mention_fixture!(techco, m2)

    # Gap: Alice → Phoenix (candidate)
    %{
      user: user,
      entities: %{alice: alice, techco: techco, phoenix: phoenix},
      memories: %{alice_role: m1, phoenix_need: m2}
    }
  end

  @doc """
  Seeds an isolated entity with no relations or mentions. Good for testing
  the "nothing to consolidate" path.
  """
  def seed_isolated!(user) do
    entity = entity_fixture!(user, "Lonely Entity", "concept", %{})
    memory = memory_fixture!(user, "Some unrelated fact about cooking.", tags: ["cooking"])

    %{user: user, entity: entity, memory: memory}
  end

  @doc """
  Seeds a fully-connected subgraph (no gaps). Good for testing that the
  consolidator doesn't propose duplicate relations.
  """
  def seed_fully_connected!(user) do
    bob = entity_fixture!(user, "Bob Martinez", "person", %{"role" => "CTO"})
    techco = entity_fixture!(user, "TechCo", "organization", %{})

    m = memory_fixture!(user, "Bob Martinez is the CTO of TechCo.", tags: ["person", "org"])

    r = relation_fixture!(bob, techco, "works_at", confidence: Decimal.new("0.95"))
    mention_fixture!(bob, m)
    mention_fixture!(techco, m)

    %{
      user: user,
      entities: %{bob: bob, techco: techco},
      memories: %{bob_role: m},
      relations: %{bob_at_techco: r}
    }
  end

  @doc """
  Seeds a temporal scenario: an entity changed roles. Old relation is closed,
  new relation is active. Good for testing temporal integrity.
  """
  def seed_role_change!(user) do
    carol = entity_fixture!(user, "Carol Park", "person", %{})
    techco = entity_fixture!(user, "TechCo", "organization", %{})
    dataflow = entity_fixture!(user, "DataFlow Labs", "organization", %{})

    m_old =
      memory_fixture!(user, "Carol Park used to work at DataFlow Labs as a product analyst.",
        tags: ["person", "organization"]
      )

    m_new =
      memory_fixture!(user, "Carol Park now works at TechCo as a product manager.",
        tags: ["person", "organization"]
      )

    # Closed relation (has valid_to)
    old_rel =
      %MemoryEntityRelation{}
      |> MemoryEntityRelation.changeset(%{
        relation_type: "works_at",
        source_entity_id: carol.id,
        target_entity_id: dataflow.id,
        confidence: Decimal.new("0.90"),
        valid_to: DateTime.utc_now()
      })
      |> Repo.insert!()

    # Active relation
    new_rel = relation_fixture!(carol, techco, "works_at", confidence: Decimal.new("0.95"))

    mention_fixture!(carol, m_old)
    mention_fixture!(carol, m_new)
    mention_fixture!(dataflow, m_old)
    mention_fixture!(techco, m_new)

    %{
      user: user,
      entities: %{carol: carol, techco: techco, dataflow: dataflow},
      memories: %{old: m_old, new: m_new},
      relations: %{old_rel: old_rel, new_rel: new_rel}
    }
  end

  @doc """
  Seeds a marketing + finance cross-domain scenario for testing
  consolidation across business functions.
  """
  def seed_cross_domain!(user) do
    frank = entity_fixture!(user, "Frank Torres", "person", %{"role" => "CMO"})
    grace = entity_fixture!(user, "Grace Kim", "person", %{"role" => "CFO"})
    techco = entity_fixture!(user, "TechCo", "organization", %{})
    brand = entity_fixture!(user, "Brand Relaunch", "project", %{"budget" => "$2M"})
    series_c = entity_fixture!(user, "Series C", "project", %{"target" => "$50M"})
    vertex = entity_fixture!(user, "Vertex Partners", "organization", %{"type" => "VC"})

    m1 =
      memory_fixture!(
        user,
        "Frank Torres is the CMO leading TechCo's $2M Brand Relaunch campaign for Q3.",
        tags: ["person", "marketing", "project"]
      )

    m2 =
      memory_fixture!(
        user,
        "Grace Kim is negotiating the Series C with Vertex Partners. They want to see Q1 numbers.",
        tags: ["person", "finance", "fundraise"]
      )

    m3 =
      memory_fixture!(
        user,
        "Email from Grace to Frank: 'Hold Brand Relaunch spend until Series C term sheet is signed. Budget freeze until April.'",
        tags: ["email", "finance", "marketing"],
        category: "email"
      )

    relation_fixture!(frank, techco, "works_at")
    relation_fixture!(grace, techco, "works_at")
    mention_fixture!(frank, m1)
    mention_fixture!(frank, m3)
    mention_fixture!(grace, m2)
    mention_fixture!(grace, m3)
    mention_fixture!(techco, m1)
    mention_fixture!(brand, m1)
    mention_fixture!(brand, m3)
    mention_fixture!(series_c, m2)
    mention_fixture!(vertex, m2)

    # Gaps: Frank→Brand (manages), Grace→Series C (manages), Vertex→TechCo (related_to),
    #        Brand→TechCo (part_of), Series C→TechCo (part_of), Frank works_with Grace
    %{
      user: user,
      entities: %{
        frank: frank,
        grace: grace,
        techco: techco,
        brand: brand,
        series_c: series_c,
        vertex: vertex
      },
      memories: %{frank_role: m1, grace_fundraise: m2, budget_email: m3}
    }
  end
end
