# lib/assistant/channels/thinking_messages.ex — Random thinking/typing indicator messages.
#
# Provides fun randomized messages shown to users while the assistant is
# processing their request. Used by channel controllers to replace the
# static "Thinking..." placeholder.
#
# Related files:
#   - lib/assistant_web/controllers/google_chat_controller.ex (uses random/0)
#   - lib/assistant_web/controllers/telegram_controller.ex (uses random/0)
#   - lib/assistant_web/controllers/slack_controller.ex (uses random/0)

defmodule Assistant.Channels.ThinkingMessages do
  @moduledoc false

  @messages [
    "Brewing up a response... ☕",
    "Neurons firing...",
    "Consulting my digital brain...",
    "Hmm, let me think about that...",
    "Processing at the speed of thought...",
    "Crunching the bits...",
    "One moment, having a think...",
    "Spinning up the hamster wheels...",
    "Let me put my thinking cap on...",
    "Diving into the knowledge vault...",
    "Hold that thought... actually, I've got it...",
    "My synapses are tingling...",
    "Channeling my inner genius...",
    "Running it through the neural networks...",
    "Warming up the brain cells...",
    "Give me a sec, this is a good one...",
    "Loading wisdom... 87% complete...",
    "Asking the wise bytes...",
    "Pondering the imponderable...",
    "On it like a bonnet..."
  ]

  @doc "Returns a random thinking message."
  @spec random() :: String.t()
  def random, do: Enum.random(@messages)
end
