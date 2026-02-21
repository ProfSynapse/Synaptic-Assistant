# lib/assistant/skills/images/generate.ex — Handler for images.generate skill.
#
# Generates images through OpenRouter's image-capable chat models. Supports
# provider-specific options (size, aspect_ratio, n), writes data-URL images
# to disk, and returns file paths/URLs for downstream agent use.
#
# Related files:
#   - lib/assistant/integrations/openrouter.ex (OpenRouter API client)
#   - lib/assistant/config/loader.ex (model defaults from config.yaml)
#   - priv/skills/images/generate.md (skill definition)

defmodule Assistant.Skills.Images.Generate do
  @moduledoc """
  Skill handler for OpenRouter image generation.

  Uses an image-capable model via `Assistant.Integrations.OpenRouter.image_generation/2`.
  Decodes data URL images to files under the workspace (or system temp dir) and
  returns a summary with local paths and remote URLs.
  """

  @behaviour Assistant.Skills.Handler

  alias Assistant.Config.Loader, as: ConfigLoader
  alias Assistant.Integrations.OpenRouter
  alias Assistant.Skills.Result

  @default_model "openai/gpt-5-image-mini"
  @default_image_count 1
  @max_image_count 4
  @output_subdir "generated_images"

  @impl true
  def execute(flags, context) do
    openrouter = Map.get(context.integrations, :openrouter, OpenRouter)
    prompt = flags["prompt"]
    model = resolve_model(flags["model"])
    size = flags["size"]
    aspect_ratio = flags["aspect_ratio"] || flags["aspect"]

    api_key = resolve_openrouter_key(context.user_id)

    with :ok <- validate_prompt(prompt),
         {:ok, image_count} <- parse_image_count(flags["n"]),
         {:ok, output_dir} <- ensure_output_dir(context.workspace_path),
         {:ok, response} <-
           request_image_generation(
             openrouter,
             String.trim(prompt),
             model,
             image_count,
             size,
             aspect_ratio,
             api_key
           ) do
      build_success_result(response, model, output_dir)
    else
      {:error, message} when is_binary(message) ->
        {:ok, %Result{status: :error, content: message}}

      {:error, reason} ->
        {:ok,
         %Result{status: :error, content: "Image generation failed: #{format_error(reason)}"}}
    end
  end

  defp validate_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      {:error, "Missing required parameter: --prompt (image description)."}
    else
      :ok
    end
  end

  defp validate_prompt(_),
    do: {:error, "Missing required parameter: --prompt (image description)."}

  defp parse_image_count(nil), do: {:ok, @default_image_count}
  defp parse_image_count(""), do: {:ok, @default_image_count}

  defp parse_image_count(value) when is_integer(value) do
    if value >= 1 and value <= @max_image_count do
      {:ok, value}
    else
      {:error, "--n must be between 1 and #{@max_image_count}."}
    end
  end

  defp parse_image_count(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> parse_image_count(int)
      _ -> {:error, "--n must be an integer between 1 and #{@max_image_count}."}
    end
  end

  defp parse_image_count(_),
    do: {:error, "--n must be an integer between 1 and #{@max_image_count}."}

  defp ensure_output_dir(nil) do
    ensure_output_dir(System.tmp_dir!())
  end

  defp ensure_output_dir(workspace_path) when is_binary(workspace_path) do
    output_dir = Path.join(workspace_path, @output_subdir)

    case File.mkdir_p(output_dir) do
      :ok -> {:ok, output_dir}
      {:error, reason} -> {:error, "Failed to create output directory: #{inspect(reason)}"}
    end
  end

  defp request_image_generation(openrouter, prompt, model, image_count, size, aspect_ratio, api_key) do
    opts =
      [model: model, n: image_count, api_key: api_key]
      |> maybe_put_opt(:size, size)
      |> maybe_put_opt(:aspect_ratio, aspect_ratio)

    case openrouter.image_generation(prompt, opts) do
      {:ok, response} ->
        {:ok, response}

      {:error, {:rate_limited, retry_after}} ->
        {:error, "OpenRouter rate limited image generation. Retry after #{retry_after}s."}

      {:error, {:insufficient_credits, message}} ->
        details = message || "insufficient credits"
        {:error, "OpenRouter rejected image generation: #{details}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_success_result(response, model, output_dir) do
    images = response[:images] || []

    if images == [] do
      {:ok,
       %Result{
         status: :error,
         content:
           "OpenRouter returned no images for this prompt. Try adjusting the prompt or switching models."
       }}
    else
      {saved_files, remote_urls, warnings} = persist_images(images, output_dir)
      content = build_content(model, saved_files, remote_urls, response[:content], warnings)

      {:ok,
       %Result{
         status: :ok,
         content: content,
         files_produced:
           Enum.map(saved_files, fn file ->
             %{path: file.path, name: Path.basename(file.path), mime_type: file.mime_type}
           end),
         side_effects: [:image_generated],
         metadata: %{
           model: model,
           image_count: length(images),
           saved_paths: Enum.map(saved_files, & &1.path),
           remote_urls: remote_urls,
           finish_reason: response[:finish_reason],
           usage: response[:usage]
         }
       }}
    end
  end

  defp persist_images(images, output_dir) do
    timestamp = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

    Enum.with_index(images, 1)
    |> Enum.reduce({[], [], []}, fn {image, index}, {saved, urls, warnings} ->
      case persist_image(image, output_dir, timestamp, index) do
        {:saved, file_info} ->
          {[file_info | saved], urls, warnings}

        {:remote_url, url} ->
          {saved, [url | urls], warnings}

        {:warning, warning} ->
          {saved, urls, [warning | warnings]}
      end
    end)
    |> then(fn {saved, urls, warnings} ->
      {Enum.reverse(saved), Enum.reverse(urls), Enum.reverse(warnings)}
    end)
  end

  defp persist_image(image, output_dir, timestamp, index) do
    url = image[:url] || image["url"]
    mime_type = image[:mime_type] || image["mime_type"] || "image/png"

    cond do
      not is_binary(url) or url == "" ->
        {:warning, "Image #{index} missing URL payload."}

      String.starts_with?(url, "data:") ->
        persist_data_url(url, mime_type, output_dir, timestamp, index)

      true ->
        {:remote_url, url}
    end
  end

  defp persist_data_url(data_url, mime_type, output_dir, timestamp, index) do
    case parse_data_url(data_url) do
      {:ok, parsed_mime, binary} ->
        final_mime = parsed_mime || mime_type
        extension = extension_for_mime(final_mime)
        filename = "image_#{timestamp}_#{index}.#{extension}"
        path = Path.join(output_dir, filename)

        case File.write(path, binary) do
          :ok -> {:saved, %{path: path, mime_type: final_mime}}
          {:error, reason} -> {:warning, "Failed to save image #{index}: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:warning, "Failed to decode image #{index}: #{reason}"}
    end
  end

  defp parse_data_url(data_url) do
    case Regex.run(~r/^data:([^;]+);base64,(.+)$/s, data_url, capture: :all_but_first) do
      [mime_type, encoded] ->
        case Base.decode64(encoded, ignore: :whitespace) do
          {:ok, binary} -> {:ok, mime_type, binary}
          :error -> {:error, "invalid base64 payload"}
        end

      _ ->
        {:error, "invalid data URL"}
    end
  end

  defp extension_for_mime("image/png"), do: "png"
  defp extension_for_mime("image/jpeg"), do: "jpg"
  defp extension_for_mime("image/webp"), do: "webp"
  defp extension_for_mime("image/gif"), do: "gif"
  defp extension_for_mime(_), do: "png"

  defp build_content(model, saved_files, remote_urls, response_text, warnings) do
    lines = [
      "Generated #{length(saved_files) + length(remote_urls)} image(s) with model: #{model}"
    ]

    lines =
      if saved_files == [] do
        lines
      else
        lines ++
          ["Saved files:"] ++
          Enum.map(saved_files, fn file -> "- #{file.path}" end)
      end

    lines =
      if remote_urls == [] do
        lines
      else
        lines ++
          ["Remote URLs:"] ++
          Enum.map(remote_urls, fn url -> "- #{url}" end)
      end

    lines =
      if is_binary(response_text) and String.trim(response_text) != "" do
        lines ++ ["Model note: #{String.trim(response_text)}"]
      else
        lines
      end

    lines =
      if warnings == [] do
        lines
      else
        lines ++ ["Warnings:"] ++ Enum.map(warnings, fn warning -> "- #{warning}" end)
      end

    Enum.join(lines, "\n")
  end

  defp maybe_put_opt(opts, _key, nil), do: opts

  defp maybe_put_opt(opts, key, value) when is_binary(value) do
    if String.trim(value) == "" do
      opts
    else
      Keyword.put(opts, key, String.trim(value))
    end
  end

  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp resolve_model(model) when is_binary(model) do
    if String.trim(model) == "" do
      resolve_default_model()
    else
      String.trim(model)
    end
  end

  defp resolve_model(_), do: resolve_default_model()

  defp resolve_default_model do
    case maybe_lookup_config_model() do
      {:ok, id} -> id
      _ -> @default_model
    end
  end

  defp maybe_lookup_config_model do
    case ConfigLoader.model_for(:image_generation) do
      %{id: id} when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :config_unavailable}
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp resolve_openrouter_key(user_id) when is_binary(user_id),
    do: Assistant.Accounts.openrouter_key_for_user(user_id)

  defp resolve_openrouter_key(_), do: nil
end
