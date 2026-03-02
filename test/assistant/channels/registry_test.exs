# test/assistant/channels/registry_test.exs
#
# Tests for the channel Registry module that maps channel atoms to adapter modules.

defmodule Assistant.Channels.RegistryTest do
  use ExUnit.Case, async: true

  alias Assistant.Channels.Registry

  describe "adapter_for/1" do
    test "returns Google Chat adapter for :google_chat" do
      assert {:ok, Assistant.Channels.GoogleChat} = Registry.adapter_for(:google_chat)
    end

    test "returns Telegram adapter for :telegram" do
      assert {:ok, Assistant.Channels.Telegram} = Registry.adapter_for(:telegram)
    end

    test "returns Slack adapter for :slack" do
      assert {:ok, Assistant.Channels.Slack} = Registry.adapter_for(:slack)
    end

    test "returns Discord adapter for :discord" do
      assert {:ok, Assistant.Channels.Discord} = Registry.adapter_for(:discord)
    end

    test "returns error for unregistered channel" do
      assert {:error, :unknown_channel} = Registry.adapter_for(:whatsapp)
    end

    test "returns error for unknown atom" do
      assert {:error, :unknown_channel} = Registry.adapter_for(:nonexistent)
    end
  end

  describe "all_channels/0" do
    test "returns all four registered channel atoms" do
      channels = Registry.all_channels()
      assert :google_chat in channels
      assert :telegram in channels
      assert :slack in channels
      assert :discord in channels
      assert length(channels) == 4
    end
  end

  describe "all_adapters/0" do
    test "returns all four registered adapter modules" do
      adapters = Registry.all_adapters()
      assert Assistant.Channels.GoogleChat in adapters
      assert Assistant.Channels.Telegram in adapters
      assert Assistant.Channels.Slack in adapters
      assert Assistant.Channels.Discord in adapters
      assert length(adapters) == 4
    end
  end

  describe "registered?/1" do
    test "returns true for registered channels" do
      assert Registry.registered?(:google_chat)
      assert Registry.registered?(:telegram)
      assert Registry.registered?(:slack)
      assert Registry.registered?(:discord)
    end

    test "returns false for unregistered channels" do
      refute Registry.registered?(:whatsapp)
      refute Registry.registered?(:signal)
    end
  end
end
