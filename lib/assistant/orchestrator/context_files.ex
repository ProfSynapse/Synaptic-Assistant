defmodule Assistant.Orchestrator.ContextFiles do
  @moduledoc false

  alias Assistant.Config.Loader
  alias Assistant.Integrations.LLMRouter
  alias Assistant.Sync.{FileManager, StateStore}

  require Logger

  @text_formats ~w(md csv txt json)
  @image_formats ~w(png jpg webp gif)
  @document_formats ~w(pdf)
  @max_asset_count 5
  @max_asset_bytes 20_000_000
  @max_total_asset_bytes 40_000_000

  @type loaded :: %{
          prompt_prefix: String.t(),
          messages: [map()]
        }

  @spec load([String.t()], keyword()) ::
          {:ok, loaded()}
          | {:error,
             {:context_budget_exceeded,
              %{
                estimated_tokens: non_neg_integer(),
                budget_tokens: non_neg_integer(),
                overage_tokens: non_neg_integer(),
                files: [map()]
              }}}
  def load([], _opts), do: {:ok, %{prompt_prefix: "", messages: []}}

  def load(file_paths, opts) when is_list(file_paths) do
    provider = Keyword.get(opts, :provider) || routed_provider(opts)
    model_info = Keyword.get(opts, :model_info)
    budget_tokens = Keyword.fetch!(opts, :budget_tokens)

    loaded =
      Enum.reduce(file_paths, %{texts: [], assets: [], warnings: []}, fn path, acc ->
        case load_entry(path, opts) do
          {:ok, entry} ->
            classify_entry(entry, provider, model_info, acc)

          {:warn, warning} ->
            %{acc | warnings: acc.warnings ++ [warning]}
        end
      end)

    validate_and_build(loaded, provider, budget_tokens)
  end

  defp validate_and_build(loaded, provider, budget_tokens) do
    total_tokens = Enum.reduce(loaded.texts, 0, fn entry, sum -> sum + entry.estimated_tokens end)

    if total_tokens > budget_tokens do
      file_breakdown =
        loaded.texts
        |> Enum.map(fn entry ->
          %{path: entry.path, estimated_tokens: entry.estimated_tokens}
        end)
        |> Enum.sort_by(& &1.estimated_tokens, :desc)

      {:error,
       {:context_budget_exceeded,
        %{
          estimated_tokens: total_tokens,
          budget_tokens: budget_tokens,
          overage_tokens: total_tokens - budget_tokens,
          files: file_breakdown
        }}}
    else
      asset_result = build_asset_messages(loaded.assets, loaded.warnings, provider)

      {:ok,
       %{
         prompt_prefix: build_prompt_prefix(loaded.texts, asset_result.warnings),
         messages: asset_result.messages
       }}
    end
  end

  defp build_prompt_prefix([], []), do: ""

  defp build_prompt_prefix(texts, warnings) do
    sections =
      []
      |> maybe_add_text_docs(texts)
      |> maybe_add_warnings(warnings)

    Enum.join(sections, "\n\n")
  end

  defp maybe_add_text_docs(sections, []), do: sections

  defp maybe_add_text_docs(sections, texts) do
    docs =
      texts
      |> Enum.map_join("\n---\n", fn %{path: path, contents: contents} ->
        "### #{path}\n#{contents}"
      end)

    sections ++ ["## Context Documents\n#{docs}"]
  end

  defp maybe_add_warnings(sections, []), do: sections

  defp maybe_add_warnings(sections, warnings) do
    notes =
      warnings
      |> Enum.uniq()
      |> Enum.map_join("\n", &"- #{&1}")

    sections ++ ["## Context File Notes\n#{notes}"]
  end

  defp build_asset_messages([], warnings, _provider), do: %{messages: [], warnings: warnings}

  defp build_asset_messages(assets, warnings, provider) do
    {asset_entries, asset_warnings} = trim_supported_assets(assets)
    warnings = warnings ++ asset_warnings

    case Enum.map(asset_entries, &asset_part(provider, &1)) do
      [] ->
        %{messages: [], warnings: warnings}

      parts ->
        intro =
          asset_entries
          |> Enum.map_join("\n", fn entry ->
            "- #{entry.path} (#{asset_label(entry)})"
          end)
          |> then(&"Use these context assets if relevant to the task:\n#{&1}")

        %{
          messages: [%{role: "user", content: [%{type: "text", text: intro} | parts]}],
          warnings: warnings
        }
    end
  end

  defp trim_supported_assets(assets) do
    {within_count, overflow} = Enum.split(assets, @max_asset_count)
    warnings = overflow_warnings(overflow)

    {kept, _size, warnings} =
      Enum.reduce(within_count, {[], 0, warnings}, fn entry, {acc, total_bytes, acc_warnings} ->
        cond do
          entry.byte_size > @max_asset_bytes ->
            {acc, total_bytes,
             acc_warnings ++
               ["Skipped #{entry.path}: asset exceeds #{@max_asset_bytes} byte limit."]}

          total_bytes + entry.byte_size > @max_total_asset_bytes ->
            {acc, total_bytes,
             acc_warnings ++
               ["Skipped #{entry.path}: total context asset budget exceeded."]}

          true ->
            {[entry | acc], total_bytes + entry.byte_size, acc_warnings}
        end
      end)

    {Enum.reverse(kept), warnings}
  end

  defp overflow_warnings([]), do: []

  defp overflow_warnings(entries) do
    Enum.map(entries, fn entry ->
      "Skipped #{entry.path}: only #{@max_asset_count} multimodal context assets are allowed."
    end)
  end

  defp asset_part(:openrouter, %{kind: :image} = entry) do
    %{
      type: "image_url",
      image_url: %{url: data_url(entry.mime_type, entry.contents)}
    }
  end

  defp asset_part(:openrouter, %{kind: :document} = entry) do
    %{
      type: "file",
      file: %{
        filename: entry.name,
        file_data: data_url(entry.mime_type, entry.contents)
      }
    }
  end

  defp asset_part(:openai, %{kind: :document} = entry) do
    %{
      type: "file",
      file: %{
        filename: entry.name,
        file_data: data_url(entry.mime_type, entry.contents)
      }
    }
  end

  defp asset_part(:openai, %{kind: :image} = entry) do
    %{
      type: "image_url",
      image_url: %{url: data_url(entry.mime_type, entry.contents)}
    }
  end

  defp asset_label(%{kind: :image}), do: "image"
  defp asset_label(%{kind: :document}), do: "pdf"

  defp load_entry(path, opts) do
    user_id = Keyword.get(opts, :user_id)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    state_store = Keyword.get(opts, :state_store, StateStore)
    file_manager = Keyword.get(opts, :file_manager, FileManager)
    agent_id = Keyword.get(opts, :agent_id)

    case load_from_filesystem(path, cwd) do
      {:ok, entry} ->
        {:ok, entry}

      {:warn, _reason} ->
        load_from_workspace(path, user_id, state_store, file_manager, agent_id)
    end
  end

  defp load_from_filesystem(path, cwd) do
    case resolve_filesystem_path(path, cwd) do
      {:ok, resolved} ->
        case File.read(resolved) do
          {:ok, contents} ->
            local_format = infer_local_format(path)
            mime_type = mime_type_for_format(local_format)

            {:ok,
             %{
               path: path,
               name: Path.basename(path),
               contents: contents,
               local_format: local_format,
               mime_type: mime_type,
               estimated_tokens: estimated_tokens(contents),
               byte_size: byte_size(contents)
             }}

          {:error, _reason} ->
            {:warn, :missing}
        end

      {:error, _reason} ->
        {:warn, :path_not_allowed}
    end
  end

  defp load_from_workspace(path, user_id, state_store, file_manager, agent_id)
       when is_binary(user_id) do
    case state_store.get_synced_file_by_local_path(user_id, path) do
      nil ->
        {:warn, "Skipped #{path}: file not found in project or workspace."}

      %{content: nil} ->
        {:warn, "Skipped #{path}: workspace file has no synced content."}

      synced_file ->
        case file_manager.read_file(user_id, path) do
          {:ok, contents} ->
            {:ok,
             %{
               path: path,
               name: Path.basename(path),
               contents: contents,
               local_format: synced_file.local_format,
               mime_type:
                 synced_file.drive_mime_type || mime_type_for_format(synced_file.local_format),
               estimated_tokens: estimated_tokens(contents),
               byte_size: byte_size(contents)
             }}

          {:error, reason} ->
            Logger.warning("Context workspace file not readable — skipping",
              path: path,
              reason: inspect(reason),
              agent_id: agent_id
            )

            {:warn, "Skipped #{path}: workspace file is not readable."}
        end
    end
  end

  defp load_from_workspace(path, _user_id, _state_store, _file_manager, _agent_id) do
    {:warn, "Skipped #{path}: file not found in project."}
  end

  defp classify_entry(entry, provider, model_info, acc) do
    cond do
      entry.local_format in @text_formats ->
        %{acc | texts: acc.texts ++ [entry]}

      entry.local_format in @image_formats ->
        if image_supported?(provider, model_info) do
          %{acc | assets: acc.assets ++ [Map.put(entry, :kind, :image)]}
        else
          %{
            acc
            | warnings:
                acc.warnings ++ ["Skipped #{entry.path}: selected model cannot ingest images."]
          }
        end

      entry.local_format in @document_formats ->
        if document_supported?(provider, model_info) do
          %{acc | assets: acc.assets ++ [Map.put(entry, :kind, :document)]}
        else
          %{
            acc
            | warnings:
                acc.warnings ++
                  ["Skipped #{entry.path}: selected model cannot ingest PDFs."]
          }
        end

      true ->
        %{
          acc
          | warnings: acc.warnings ++ ["Skipped #{entry.path}: unsupported context file type."]
        }
    end
  end

  defp image_supported?(_provider, nil), do: false

  defp image_supported?(_provider, model_info),
    do: Loader.model_supports_input?(model_info, :image)

  defp document_supported?(_provider, nil), do: false

  defp document_supported?(_provider, model_info),
    do: Loader.model_supports_input?(model_info, :document)

  defp routed_provider(opts) do
    llm_router = Keyword.get(opts, :llm_router, LLMRouter)
    model_id = Keyword.get(opts, :model)
    user_id = Keyword.get(opts, :user_id)

    llm_router.route(model_id, user_id).provider
  end

  defp resolve_filesystem_path(path, cwd) do
    resolved =
      if Path.type(path) == :absolute do
        Path.expand(path)
      else
        Path.expand(path, cwd)
      end

    if String.starts_with?(resolved, cwd <> "/") or resolved == cwd do
      {:ok, resolved}
    else
      {:error, :path_traversal_denied}
    end
  end

  defp estimated_tokens(contents), do: div(byte_size(contents), 4)

  defp infer_local_format(path) do
    case path |> Path.extname() |> String.downcase() do
      ".md" -> "md"
      ".csv" -> "csv"
      ".txt" -> "txt"
      ".json" -> "json"
      ".pdf" -> "pdf"
      ".png" -> "png"
      ".jpg" -> "jpg"
      ".jpeg" -> "jpg"
      ".webp" -> "webp"
      ".gif" -> "gif"
      _ -> "bin"
    end
  end

  defp mime_type_for_format("md"), do: "text/markdown"
  defp mime_type_for_format("csv"), do: "text/csv"
  defp mime_type_for_format("txt"), do: "text/plain"
  defp mime_type_for_format("json"), do: "application/json"
  defp mime_type_for_format("pdf"), do: "application/pdf"
  defp mime_type_for_format("png"), do: "image/png"
  defp mime_type_for_format("jpg"), do: "image/jpeg"
  defp mime_type_for_format("webp"), do: "image/webp"
  defp mime_type_for_format("gif"), do: "image/gif"
  defp mime_type_for_format(_format), do: "application/octet-stream"

  defp data_url(mime_type, contents) do
    "data:#{mime_type};base64,#{Base.encode64(contents)}"
  end
end
