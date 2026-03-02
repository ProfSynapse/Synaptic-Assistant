# lib/assistant/channels/registry.ex — Channel atom-to-adapter module mapping.
#
# Provides a central registry that maps channel identifier atoms (e.g., :google_chat,
# :telegram) to their corresponding adapter modules. Used by the Dispatcher and
# any code that needs to look up channel capabilities at runtime.
#
# Related files:
#   - lib/assistant/channels/adapter.ex (behaviour that registered modules implement)
#   - lib/assistant/channels/dispatcher.ex (primary consumer of this registry)
#   - lib/assistant/channels/google_chat.ex (registered adapter)
#   - lib/assistant/channels/telegram.ex (registered adapter)
#   - lib/assistant/channels/slack.ex (registered adapter)
#   - lib/assistant/channels/discord.ex (registered adapter)

defmodule Assistant.Channels.Registry do
  @moduledoc """
  Maps channel identifier atoms to their adapter modules.

  ## Usage

      iex> Registry.adapter_for(:google_chat)
      {:ok, Assistant.Channels.GoogleChat}

      iex> Registry.adapter_for(:unknown)
      {:error, :unknown_channel}

      iex> Registry.all_channels()
      [:google_chat]
  """

  @adapters %{
    google_chat: Assistant.Channels.GoogleChat,
    telegram: Assistant.Channels.Telegram,
    slack: Assistant.Channels.Slack,
    discord: Assistant.Channels.Discord
  }

  @doc "Look up the adapter module for a channel atom."
  @spec adapter_for(atom()) :: {:ok, module()} | {:error, :unknown_channel}
  def adapter_for(channel) when is_atom(channel) do
    case Map.fetch(@adapters, channel) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :unknown_channel}
    end
  end

  @doc "Return all registered channel atoms."
  @spec all_channels() :: [atom()]
  def all_channels, do: Map.keys(@adapters)

  @doc "Return all registered adapter modules."
  @spec all_adapters() :: [module()]
  def all_adapters, do: Map.values(@adapters)

  @doc "Check whether a channel atom is registered."
  @spec registered?(atom()) :: boolean()
  def registered?(channel) when is_atom(channel) do
    Map.has_key?(@adapters, channel)
  end
end
