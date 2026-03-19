defmodule Assistant.TranscriptsTest do
  use Assistant.DataCase, async: false

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

  test "list_transcripts uses plaintext preview and body query outside hosted mode" do
    Application.put_env(:assistant, :content_crypto, mode: :local_cloak)
    conversation = conversation_fixture()
    message_fixture(conversation, %{content: "super secret preview"})

    [row] = Transcripts.list_transcripts(query: "secret")

    assert row.id == conversation.id
    assert row.preview == "super secret preview"
  end

  test "list_transcripts suppresses preview and body substring search in hosted mode" do
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
