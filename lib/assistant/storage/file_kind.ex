defmodule Assistant.Storage.FileKind do
  @moduledoc """
  Provider-neutral file kind normalization.
  """

  @doc_mime_types [
    "application/vnd.google-apps.document",
    "application/msword",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "application/vnd.oasis.opendocument.text",
    "application/rtf",
    "text/rtf"
  ]

  @sheet_mime_types [
    "application/vnd.google-apps.spreadsheet",
    "application/vnd.ms-excel",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "application/vnd.oasis.opendocument.spreadsheet",
    "text/csv",
    "application/csv",
    "text/tab-separated-values"
  ]

  @slides_mime_types [
    "application/vnd.google-apps.presentation",
    "application/vnd.ms-powerpoint",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    "application/vnd.oasis.opendocument.presentation"
  ]

  @doc_extensions ~w(md markdown txt doc docx odt rtf)
  @sheet_extensions ~w(csv tsv xls xlsx ods)
  @slides_extensions ~w(ppt pptx odp)
  @image_extensions ~w(png jpg jpeg gif webp bmp tif tiff svg heic)

  @spec normalize(String.t() | nil, String.t() | nil) :: String.t()
  def normalize(mime_type, name \\ nil)

  def normalize(mime_type, name) when is_binary(mime_type) do
    ext = extension(name)

    cond do
      mime_type in @sheet_mime_types or ext in @sheet_extensions -> "sheet"
      mime_type in @slides_mime_types or ext in @slides_extensions -> "slides"
      mime_type == "application/pdf" or ext == "pdf" -> "pdf"
      String.starts_with?(mime_type, "image/") or ext in @image_extensions -> "image"
      mime_type in @doc_mime_types or ext in @doc_extensions -> "doc"
      String.starts_with?(mime_type, "text/") -> "doc"
      true -> "file"
    end
  end

  def normalize(_mime_type, name) when is_binary(name) do
    case extension(name) do
      ext when ext in @sheet_extensions -> "sheet"
      ext when ext in @slides_extensions -> "slides"
      "pdf" -> "pdf"
      ext when ext in @image_extensions -> "image"
      ext when ext in @doc_extensions -> "doc"
      _ -> "file"
    end
  end

  def normalize(_, _), do: "file"

  defp extension(name) when is_binary(name) do
    case Path.extname(name) do
      "" -> nil
      ext -> ext |> String.trim_leading(".") |> String.downcase()
    end
  end
end
