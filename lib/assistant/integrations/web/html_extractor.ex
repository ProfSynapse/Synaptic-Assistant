defmodule Assistant.Integrations.Web.HtmlExtractor do
  @moduledoc """
  HTML-to-text extraction for fetched web pages.
  """

  @spec extract(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def extract(body, opts \\ [])

  def extract(body, opts) when is_binary(body) do
    selector = Keyword.get(opts, :selector)
    cleaned = strip_non_content_tags(body)

    with {:ok, document} <- Floki.parse_document(cleaned) do
      nodes = select_nodes(document, selector)

      {:ok,
       %{
         title: extract_title(document),
         canonical_url: extract_canonical_url(document),
         content: normalize_text(Floki.text(nodes, sep: "\n"))
       }}
    end
  end

  def extract(_, _), do: {:error, :invalid_body}

  defp select_nodes(document, selector) when is_binary(selector) and selector != "" do
    case Floki.find(document, selector) do
      [] -> fallback_nodes(document)
      nodes -> nodes
    end
  end

  defp select_nodes(document, _selector), do: fallback_nodes(document)

  defp fallback_nodes(document) do
    cond do
      Floki.find(document, "article") != [] -> Floki.find(document, "article")
      Floki.find(document, "main") != [] -> Floki.find(document, "main")
      true -> Floki.find(document, "body")
    end
  end

  defp extract_title(document) do
    document
    |> Floki.find("title")
    |> Floki.text(sep: " ")
    |> String.trim()
    |> blank_to_nil()
  end

  defp extract_canonical_url(document) do
    document
    |> Floki.attribute("link[rel='canonical']", "href")
    |> List.first()
    |> blank_to_nil()
  end

  defp strip_non_content_tags(body) do
    body
    |> then(&Regex.replace(~r/<script\b[^>]*>.*?<\/script>/is, &1, " "))
    |> then(&Regex.replace(~r/<style\b[^>]*>.*?<\/style>/is, &1, " "))
    |> then(&Regex.replace(~r/<noscript\b[^>]*>.*?<\/noscript>/is, &1, " "))
    |> then(&Regex.replace(~r/<svg\b[^>]*>.*?<\/svg>/is, &1, " "))
  end

  defp normalize_text(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> then(&Regex.replace(~r/[ \t]+\n/, &1, "\n"))
    |> then(&Regex.replace(~r/\n{3,}/, &1, "\n\n"))
    |> String.trim()
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end
end
