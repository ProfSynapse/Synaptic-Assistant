# lib/assistant/skills/context.ex — SkillContext struct.
#
# Injected into every skill handler's execute/2 call. Provides
# the execution environment: who is running the skill, which
# conversation it belongs to, and which integration clients are
# available. The channel field identifies the originating adapter.

defmodule Assistant.Skills.Context do
  @moduledoc """
  Execution context injected into skill handlers.

  Carries identity, conversation state, integration clients, and
  execution metadata needed by handlers to perform their work.

  ## Fields

    * `:conversation_id` - UUID of the active conversation
    * `:execution_id` - Unique ID for this skill execution (for tracing)
    * `:user_id` - UUID of the user who triggered the skill
    * `:channel` - Originating channel adapter (e.g., `:telegram`, `:google_chat`)
    * `:timezone` - User's IANA timezone (e.g., "America/New_York")
    * `:workspace_path` - Temp directory path for file-manipulating skills
    * `:integrations` - Map of available integration client modules
    * `:metadata` - Arbitrary additional context
  """

  @type t :: %__MODULE__{
          conversation_id: String.t(),
          execution_id: String.t(),
          user_id: String.t(),
          channel: atom() | nil,
          timezone: String.t() | nil,
          workspace_path: String.t() | nil,
          integrations: integrations(),
          metadata: map()
        }

  @type integrations :: %{
          optional(:drive) => module(),
          optional(:gmail) => module(),
          optional(:calendar) => module(),
          optional(:hubspot) => module()
        }

  @enforce_keys [:conversation_id, :execution_id, :user_id]
  defstruct [
    :conversation_id,
    :execution_id,
    :user_id,
    :channel,
    :timezone,
    :workspace_path,
    integrations: %{},
    metadata: %{}
  ]
end
