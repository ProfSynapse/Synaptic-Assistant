defmodule Assistant.TranscriptsTest do
  use Assistant.DataCase, async: false

  alias Assistant.Encryption.BlindIndex
  alias Assistant.Repo
  alias Assistant.Schemas.{Conversation, Message, User}
  alias Assistant.Transcripts

  setup do
    original = Application.get_env(:assistant, :content_crypto)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:assistant, :content_crypto)
      else
        Application.put_env(:assistant, :content_crypto, original)
      end
    end)

    :ok
  end

  test "list_transcripts returns blank preview outside hosted mode and ID queries work" do
    Application.put_env(:assistant, :content_crypto, mode: :local_cloak)
    conversation = conversation_fixture()
    message_fixture(conversation, %{content: "super secret preview"})

    [row] = Transcripts.list_transcripts(query: conversation.id)

    assert row.id == conversation.id
    assert row.preview == ""
  end

  test "list_transcripts suppresses preview in hosted mode and ID queries work" do
    Application.put_env(:assistant, :content_crypto, mode: :vault_transit)
    conversation = conversation_fixture()
    message_fixture(conversation, %{content: "super secret preview"})

    [row] = Transcripts.list_transcripts()
    assert row.id == conversation.id
    assert row.preview == "Preview unavailable in hosted mode"

    assert [] == Transcripts.list_transcripts(query: "secret")
    assert [%{id: id}] = Transcripts.list_transcripts(query: conversation.id)
    assert id == conversation.id
  end

  describe "blind index transcript search" do
    test "list_transcripts finds conversations by keyword via blind index" do
      conversation = conversation_fixture()
      message = message_fixture(conversation, %{content: "the quantum flux capacitor is broken"})

      # Index the message content via blind index (using "local" fallback)
      BlindIndex.index_content("message", message.id, "the quantum flux capacitor is broken", "local")

      # Search for a keyword that exists in the message
      results = Transcripts.list_transcripts(query: "quantum")
      assert length(results) == 1
      assert hd(results).id == conversation.id

      # Multi-word search — both tokens must match
      results = Transcripts.list_transcripts(query: "flux capacitor")
      assert length(results) == 1
      assert hd(results).id == conversation.id
    end

    test "list_transcripts returns no results for non-matching keyword" do
      conversation = conversation_fixture()
      message = message_fixture(conversation, %{content: "the weather is sunny today"})

      BlindIndex.index_content("message", message.id, "the weather is sunny today", "local")

      # Search for a keyword NOT in the message
      results = Transcripts.list_transcripts(query: "quantum")
      assert results == []
    end

    test "blind index search combined with ID search returns union" do
      conversation = conversation_fixture()
      message = message_fixture(conversation, %{content: "deploy the microservice"})

      BlindIndex.index_content("message", message.id, "deploy the microservice", "local")

      # Search by conversation ID still works
      results = Transcripts.list_transcripts(query: conversation.id)
      assert length(results) == 1
      assert hd(results).id == conversation.id
    end

    test "messages indexed via Store.append_message are searchable in transcripts" do
      conversation = conversation_fixture()

      # Use Store.append_message which should auto-index via blind index
      {:ok, _msg} =
        Assistant.Memory.Store.append_message(conversation.id, %{
          role: "user",
          content: "the synaptogenesis protocol is active"
        })

      results = Transcripts.list_transcripts(query: "synaptogenesis")
      assert length(results) == 1
      assert hd(results).id == conversation.id
    end
  end

  defp conversation_fixture do
    {:ok, user} =
      %User{}
      |> User.changeset(%{
        external_id: "transcripts-user-#{System.unique_integer([:positive])}",
        channel: "test"
      })
      |> Repo.insert()

    {:ok, conversation} =
      %Conversation{}
      |> Conversation.changeset(%{
        channel: "test",
        user_id: user.id
      })
      |> Repo.insert()

    conversation
  end

  defp message_fixture(conversation, attrs) do
    defaults = %{
      role: "user",
      content: "hello",
      conversation_id: conversation.id
    }

    {:ok, message} =
      %Message{}
      |> Message.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    message
  end
end
