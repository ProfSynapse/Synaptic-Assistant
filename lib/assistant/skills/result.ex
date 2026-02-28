# lib/assistant/skills/result.ex — SkillResult struct.
#
# Returned by skill handlers after execution. Contains the outcome
# (status, content, side effects) for the orchestrator to feed back
# into the LLM context or return to the user.

defmodule Assistant.Skills.Result do
  @moduledoc """
  Structured result returned by skill handler execution.

  ## Fields

    * `:status` - Outcome atom: `:ok` or `:error`
    * `:content` - Human-readable result text for the LLM context
    * `:files_produced` - List of files created during execution
    * `:side_effects` - Atoms describing what changed (e.g., `:email_sent`)
    * `:metadata` - Arbitrary metadata for downstream processing
  """

  @type t :: %__MODULE__{
          status: :ok | :error,
          content: String.t(),
          files_produced: [file_info()],
          side_effects: [atom()],
          metadata: map()
        }

  @type file_info :: %{
          path: String.t(),
          name: String.t(),
          mime_type: String.t()
        }

  @enforce_keys [:status, :content]
  defstruct [
    :status,
    :content,
    files_produced: [],
    side_effects: [],
    metadata: %{}
  ]

  # Tool results exceeding this limit get truncated before entering message
  # history. Prevents a single oversized API response (Drive search, email
  # list, etc.) from blowing out the context window. 100 KB keeps well under
  # typical model context limits while preserving useful data.
  @max_content_chars 100_000

  @doc """
  Truncates `content` if it exceeds the safe limit for message history.

  Returns the content unchanged when within bounds. When truncated, appends
  a marker so the LLM knows data was cut.
  """
  @spec truncate_content(String.t() | nil) :: String.t() | nil
  def truncate_content(nil), do: nil
  def truncate_content(content) when byte_size(content) <= @max_content_chars, do: content

  def truncate_content(content) do
    String.slice(content, 0, @max_content_chars) <>
      "\n\n[Truncated — result exceeded #{@max_content_chars} character limit. " <>
      "Use more specific filters to narrow results.]"
  end
end
