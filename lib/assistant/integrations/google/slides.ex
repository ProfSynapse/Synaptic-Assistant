# lib/assistant/integrations/google/slides.ex — Google Slides API wrapper (read-only).
#
# Provides read-only access to Google Slides presentations via the
# Slides API v1. Used by the sync engine's Converter module to extract
# structured content from presentations for Markdown export (Drive's
# text/plain export is too lossy for slides).
#
# Related files:
#   - lib/assistant/integrations/google/drive.ex (main Drive client)
#   - lib/assistant/integrations/google/drive/changes.ex (change detection)

defmodule Assistant.Integrations.Google.Slides do
  @moduledoc """
  Google Slides API client for reading presentation structure.

  Read-only wrapper around the Slides API v1 `presentations.get` endpoint.
  Returns the full presentation structure including slides, page elements,
  and text content. The sync engine's Converter uses this to produce
  structured Markdown from slides (one heading per slide, text extracted
  from shapes).

  All public functions accept `access_token` as the first parameter,
  following the existing Google integration pattern.

  ## Usage

      {:ok, presentation} = Slides.get_presentation(access_token, "1abc...")
      # presentation.title — "Q1 Report"
      # presentation.slides — list of slide maps with text content
  """

  require Logger

  alias GoogleApi.Slides.V1.Api.Presentations
  alias GoogleApi.Slides.V1.Connection
  alias GoogleApi.Slides.V1.Model

  @doc """
  Get a presentation by ID with full slide structure.

  Returns the complete presentation including all slides, page elements,
  and text runs. This is the primary entry point for the sync converter
  to extract structured content.

  ## Parameters

    - `access_token` - OAuth2 access token string
    - `presentation_id` - The Google Slides presentation ID

  ## Returns

    - `{:ok, %{id: String.t(), title: String.t(), slides: [map()]}}` on success
    - `{:error, :not_found | term()}` on failure
  """
  @spec get_presentation(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_presentation(access_token, presentation_id) do
    conn = Connection.new(access_token)

    case Presentations.slides_presentations_get(conn, presentation_id) do
      {:ok, %Model.Presentation{} = pres} ->
        {:ok, normalize_presentation(pres)}

      {:error, %Tesla.Env{status: 404}} ->
        {:error, :not_found}

      {:error, reason} ->
        Logger.warning(
          "Slides get_presentation failed for #{presentation_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # -- Private --

  defp normalize_presentation(%Model.Presentation{} = pres) do
    slides =
      (pres.slides || [])
      |> Enum.with_index(1)
      |> Enum.map(fn {page, index} -> normalize_slide(page, index) end)

    %{
      id: pres.presentationId,
      title: pres.title,
      locale: pres.locale,
      revision_id: pres.revisionId,
      slide_count: length(slides),
      slides: slides
    }
  end

  defp normalize_slide(%Model.Page{} = page, index) do
    elements = page.pageElements || []

    text_content =
      elements
      |> Enum.flat_map(&extract_text_from_element/1)
      |> Enum.reject(&(&1 == ""))

    %{
      object_id: page.objectId,
      slide_number: index,
      text_content: text_content,
      element_count: length(elements)
    }
  end

  defp extract_text_from_element(%Model.PageElement{} = elem) do
    cond do
      elem.shape && elem.shape.text ->
        extract_text_runs(elem.shape.text)

      elem.table ->
        extract_table_text(elem.table)

      elem.elementGroup && elem.elementGroup.children ->
        Enum.flat_map(elem.elementGroup.children, &extract_text_from_element/1)

      true ->
        []
    end
  end

  defp extract_text_from_element(_), do: []

  defp extract_text_runs(%Model.TextContent{} = text_content) do
    (text_content.textElements || [])
    |> Enum.filter(& &1.textRun)
    |> Enum.map(fn elem -> (elem.textRun.content || "") |> String.trim() end)
    |> Enum.reject(&(&1 == ""))
  end

  defp extract_text_runs(_), do: []

  defp extract_table_text(%Model.Table{} = table) do
    (table.tableRows || [])
    |> Enum.flat_map(fn row ->
      (row.tableCells || [])
      |> Enum.flat_map(fn cell ->
        if cell.text, do: extract_text_runs(cell.text), else: []
      end)
    end)
  end

  defp extract_table_text(_), do: []
end
