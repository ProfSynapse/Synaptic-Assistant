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
end
