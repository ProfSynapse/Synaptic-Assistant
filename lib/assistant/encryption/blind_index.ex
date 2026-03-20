defmodule Assistant.Encryption.BlindIndex do
  @moduledoc """
  Foundation for the Blind Keyword Index, enabling exact match searches
  over encrypted data by hashing tokens consistently.

  Also provides shared query helpers so that any module needing to search
  `content_terms` can reuse the same tokenize → digest → query pipeline.
  """

  import Ecto.Query

  alias Assistant.Repo

  @doc """
  Tokenizes text by downcasing, stripping most punctuation, and splitting into
  distinct words.
  """
  def tokenize(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, "")
    |> String.split()
    |> Enum.reject(&(&1 == ""))
  end

  def tokenize(_), do: []

  @doc """
  Generates a salted, hashed digest for a given term, scoped to the billing account.
  """
  def generate_digest(term, billing_account_id)
      when is_binary(term) and is_binary(billing_account_id) do
    master_key =
      Application.get_env(:assistant, :blind_index_key) ||
        raise "Missing config for :blind_index_key"

    # Combine the master key with the billing account ID to create an org-scoped key.
    # This ensures that identical terms have different digests across organizations.
    org_key = :crypto.hash(:sha256, master_key <> billing_account_id)

    :crypto.mac(:hmac, :sha256, org_key, term)
    |> Base.encode64()
  end

  @doc """
  Processes the input text into a map of `{digest => frequency}` values.

  Returns:
      %{
        "digest1" => 2,
        "digest2" => 1
      }
  """
  def process_text(text, billing_account_id) do
    text
    |> tokenize()
    |> Enum.frequencies()
    |> Map.new(fn {term, count} ->
      digest = generate_digest(term, billing_account_id)
      {digest, count}
    end)
  end

  @doc """
  Returns owner_ids from `content_terms` whose digests match ALL tokens in the
  query text, scoped by `owner_type` and `billing_account_id`.

  Used by both memory search and transcript search to avoid duplicating the
  tokenize → digest → subquery pipeline.

  Returns `{:ok, [binary()]}` with matching owner IDs, or `{:ok, []}` if query
  text is empty/nil.
  """
  @spec matching_owner_ids(String.t() | nil, String.t(), String.t()) :: {:ok, [binary()]}
  def matching_owner_ids(query_text, billing_account_id, owner_type)

  def matching_owner_ids(nil, _billing_account_id, _owner_type), do: {:ok, []}
  def matching_owner_ids("", _billing_account_id, _owner_type), do: {:ok, []}

  def matching_owner_ids(query_text, billing_account_id, owner_type) do
    digests =
      query_text
      |> tokenize()
      |> Enum.map(&generate_digest(&1, billing_account_id))

    if Enum.empty?(digests) do
      {:ok, []}
    else
      # For each digest, find owner_ids that have that term. Intersect across
      # all digests so only owners matching ALL query tokens are returned.
      base =
        from(ct in "content_terms",
          where: ct.owner_type == ^owner_type and ct.term_digest == ^hd(digests),
          select: ct.owner_id
        )

      query =
        Enum.drop(digests, 1)
        |> Enum.reduce(base, fn digest, q ->
          from ct in q,
            where:
              ct.owner_id in subquery(
                from(ct2 in "content_terms",
                  where: ct2.owner_type == ^owner_type and ct2.term_digest == ^digest,
                  select: ct2.owner_id
                )
              )
        end)

      # content_terms stores owner_id as raw binary; cast back to string UUIDs
      ids =
        Repo.all(query)
        |> Enum.map(fn raw_id -> Ecto.UUID.cast!(raw_id) end)
        |> Enum.uniq()

      {:ok, ids}
    end
  end

  @doc """
  Indexes content into `content_terms` for the given owner. Replaces any
  existing rows for that owner.

  Used by both memory indexer and message indexer.
  """
  # Deterministic sentinel UUID used when billing_account_id is not a real UUID
  # (e.g., "local" fallback for self-hosted instances).
  @local_billing_uuid "00000000-0000-0000-0000-000000000000"

  @spec index_content(String.t(), String.t(), String.t(), String.t()) :: :ok
  def index_content(owner_type, owner_id, plaintext_content, billing_account_id) do
    frequency_map = process_text(plaintext_content, billing_account_id)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    billing_uuid = safe_uuid_dump(billing_account_id)

    rows =
      Enum.map(frequency_map, fn {digest, count} ->
        %{
          id: Ecto.UUID.dump!(Ecto.UUID.generate()),
          billing_account_id: billing_uuid,
          owner_type: owner_type,
          owner_id: Ecto.UUID.dump!(owner_id),
          field: "all",
          term_digest: digest,
          term_frequency: count,
          inserted_at: now,
          updated_at: now
        }
      end)

    # Clear out old terms and insert the new ones
    from(c in "content_terms",
      where: c.owner_type == ^owner_type and c.owner_id == type(^owner_id, :binary_id)
    )
    |> Repo.delete_all()

    unless Enum.empty?(rows) do
      Repo.insert_all("content_terms", rows)
    end

    :ok
  end

  defp safe_uuid_dump(id) do
    case Ecto.UUID.dump(id) do
      {:ok, binary} -> binary
      :error -> Ecto.UUID.dump!(@local_billing_uuid)
    end
  end
end
