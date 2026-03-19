defmodule Assistant.Repo.Migrations.AddVectorSearchHelpers do
  @moduledoc """
  Adds database-level infrastructure for multi-tenant vector search.

  Problem: The HNSW index on memory_entries.embedding is global — ANN search
  returns vectors across ALL users, then PostgreSQL filters by user_id. When a
  user owns 10% of vectors, with default ef_search=40, only ~4 results survive
  the filter on average.

  Solution (two-part):

  1. SQL function `configure_vector_search/0` — detects pgvector version and
     sets optimal session parameters:
     - pgvector >= 0.8.0: enables `hnsw.iterative_scan = relaxed_order` which
       automatically scans more of the index until enough filtered results are
       found. Also sets `hnsw.max_scan_tuples` for a safety cap.
     - pgvector < 0.8.0: raises `hnsw.ef_search` to 200 (from default 40) to
       increase the candidate pool before filtering.

  2. The HNSW index is kept global (not partitioned) because:
     - Per-user partial indexes don't scale (one index per user)
     - Table partitioning is an architectural change beyond this PR scope
     - With iterative_scan (0.8+), the global index + filter approach works
       correctly at scale

  Callers: Elixir code should call `configure_vector_search()` once per
  connection checkout (e.g., in Repo after_connect callback or at query time
  via a transaction wrapper).
  """
  use Ecto.Migration

  def up do
    # SQL function that configures pgvector session parameters based on
    # the installed extension version. Safe to call multiple times per session.
    execute("""
    CREATE OR REPLACE FUNCTION configure_vector_search()
    RETURNS void
    LANGUAGE plpgsql
    AS $$
    DECLARE
      pgvec_version text;
      major int;
      minor int;
    BEGIN
      -- Get installed pgvector version (e.g., '0.8.0', '0.7.4')
      SELECT extversion INTO pgvec_version
      FROM pg_extension
      WHERE extname = 'vector';

      IF pgvec_version IS NULL THEN
        RAISE NOTICE 'pgvector extension not found, skipping configuration';
        RETURN;
      END IF;

      -- Parse major.minor from version string
      major := split_part(pgvec_version, '.', 1)::int;
      minor := split_part(pgvec_version, '.', 2)::int;

      IF major > 0 OR (major = 0 AND minor >= 8) THEN
        -- pgvector 0.8+: use iterative scan for filtered queries.
        -- relaxed_order allows the planner to return results as it finds them
        -- rather than strict distance ordering, improving throughput.
        PERFORM set_config('hnsw.iterative_scan', 'relaxed_order', false);
        PERFORM set_config('hnsw.max_scan_tuples', '20000', false);
        -- Also raise ef_search for better recall on filtered queries
        PERFORM set_config('hnsw.ef_search', '100', false);
      ELSE
        -- pgvector < 0.8: no iterative scan, so raise ef_search to compensate
        -- for post-index filtering that reduces result count.
        -- 200 gives ~5x more candidates than default 40.
        PERFORM set_config('hnsw.ef_search', '200', false);
      END IF;
    END;
    $$
    """)
  end

  def down do
    execute("DROP FUNCTION IF EXISTS configure_vector_search()")
  end
end
