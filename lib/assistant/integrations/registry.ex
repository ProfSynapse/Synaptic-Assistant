# lib/assistant/integrations/registry.ex — Integration module registry.
#
# Provides a single function that returns the default integrations map
# for skill context construction. Centralizes the mapping between
# integration keys and their implementing modules so all context
# builders stay in sync.
#
# Related files:
#   - lib/assistant/skills/context.ex (defines the integrations type)
#   - lib/assistant/orchestrator/loop_runner.ex (consumer — main loop context)
#   - lib/assistant/orchestrator/sub_agent.ex (consumer — sub-agent context)
#   - lib/assistant/memory/agent.ex (consumer — memory agent context)

defmodule Assistant.Integrations.Registry do
  @moduledoc """
  Central registry mapping integration keys to their implementing modules.

  Returns the default integrations map used by `%Assistant.Skills.Context{}`.
  Each key corresponds to a Google API client module that skill handlers
  pull from context via `Map.get(context.integrations, :key)`.

  ## Example

      iex> integrations = Assistant.Integrations.Registry.default_integrations()
      iex> Map.has_key?(integrations, :drive)
      true
  """

  alias Assistant.Integrations.Google.{Calendar, Drive, Gmail}
  alias Assistant.Integrations.{OpenAI, OpenRouter}

  @doc """
  Returns the default integrations map for skill contexts.

  Maps integration keys to their real client modules:

    - `:drive` → `Assistant.Integrations.Google.Drive`
    - `:gmail` → `Assistant.Integrations.Google.Gmail`
    - `:calendar` → `Assistant.Integrations.Google.Calendar`
    - `:openai` → `Assistant.Integrations.OpenAI`
    - `:openrouter` → `Assistant.Integrations.OpenRouter`
  """
  @spec default_integrations() :: Assistant.Skills.Context.integrations()
  def default_integrations do
    %{
      drive: Drive,
      gmail: Gmail,
      calendar: Calendar,
      openai: OpenAI,
      openrouter: OpenRouter
    }
  end
end
