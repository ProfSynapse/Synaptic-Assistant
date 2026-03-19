defmodule Assistant.Encryption.BlindIndex do
  @moduledoc """
  Foundation for the Blind Keyword Index, enabling exact match searches
  over encrypted data by hashing tokens consistently.
  """

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
end
