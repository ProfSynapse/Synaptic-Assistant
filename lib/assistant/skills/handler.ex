# lib/assistant/skills/handler.ex — Handler behaviour for skill execution.
#
# Each built-in skill has a handler module that implements this behaviour.
# The handler receives parsed CLI flags and a SkillContext, then performs
# the action (API call, DB query, etc.) and returns a SkillResult.
# Custom/template skills (no handler) are interpreted by the LLM directly.

defmodule Assistant.Skills.Handler do
  @moduledoc """
  Behaviour for built-in skill handlers.

  Handlers implement a single `execute/2` callback. All skill metadata
  (domain, description, usage, flags) lives in the markdown file —
  handlers are pure execution.

  ## Example

      defmodule Assistant.Skills.Email.Send do
        @behaviour Assistant.Skills.Handler

        @impl true
        def execute(flags, context) do
          # Send email via Gmail API
          {:ok, %Assistant.Skills.Result{status: :ok, content: "Email sent."}}
        end
      end
  """

  @doc """
  Execute the skill with parsed CLI flags and execution context.

  The handler is responsible for validating flags (required fields,
  types, enums) and performing the actual operation.

  ## Parameters

    - `flags` - Map of parsed CLI flags (e.g., `%{"to" => "bob@co.com"}`)
    - `context` - Execution context with conversation, user, and integration info

  ## Returns

    - `{:ok, %Assistant.Skills.Result{}}` on success
    - `{:error, term()}` on failure
  """
  @callback execute(flags :: map(), context :: Assistant.Skills.Context.t()) ::
              {:ok, Assistant.Skills.Result.t()} | {:error, term()}
end
