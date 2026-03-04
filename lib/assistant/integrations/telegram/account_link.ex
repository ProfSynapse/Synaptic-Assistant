defmodule Assistant.Integrations.Telegram.AccountLink do
  @moduledoc """
  Links Telegram senders to existing application users and verifies access.

  Telegram messages are only authorized when the sender already has a linked
  `user_identity` row for the Telegram channel. New links are created from
  single-use deep-link tokens generated in the authenticated settings UI.
  """

  import Ecto.Query

  alias Assistant.Channels.Message
  alias Assistant.Integrations.Telegram.Client
  alias Assistant.Integrations.Telegram.ConnectToken
  alias Assistant.Repo
  alias Assistant.Schemas.UserIdentity

  require Logger

  @channel "telegram"

  @type link_result ::
          {:ok, :linked}
          | {:error, :invalid_token | :expired_token | :already_used_token | :already_linked}
          | {:error, :not_private_chat | :missing_token | :user_already_linked}
          | {:error, term()}

  @spec generate_connect_link(String.t(), String.t() | nil) ::
          {:ok, %{url: String.t(), bot_username: String.t(), expires_at: DateTime.t()}}
          | {:error, :bot_not_configured | :bot_username_missing | term()}
  def generate_connect_link(user_id, bot_token \\ nil) when is_binary(user_id) do
    with {:ok, %{"username" => bot_username}} <- get_bot_identity(bot_token),
         {:ok, %{token: token, expires_at: expires_at}} <- ConnectToken.generate(user_id) do
      {:ok,
       %{
         url: "https://t.me/#{bot_username}?start=#{token}",
         bot_username: bot_username,
         expires_at: expires_at
       }}
    else
      {:ok, _bot} ->
        {:error, :bot_username_missing}

      {:error, :token_not_configured} ->
        {:error, :bot_not_configured}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec linked_identity_for_user(String.t() | nil) ::
          {:ok, UserIdentity.t()} | {:error, :not_connected}
  def linked_identity_for_user(nil), do: {:error, :not_connected}

  def linked_identity_for_user(user_id) when is_binary(user_id) do
    query =
      from(ui in UserIdentity,
        where: ui.user_id == ^user_id and ui.channel == ^@channel,
        order_by: [desc: ui.inserted_at],
        limit: 1
      )

    case Repo.one(query) do
      %UserIdentity{} = identity -> {:ok, identity}
      nil -> {:error, :not_connected}
    end
  end

  @spec disconnect_user(String.t() | nil) :: {:ok, non_neg_integer()}
  def disconnect_user(nil), do: {:ok, 0}

  def disconnect_user(user_id) when is_binary(user_id) do
    {count, _} =
      from(ui in UserIdentity,
        where: ui.user_id == ^user_id and ui.channel == ^@channel
      )
      |> Repo.delete_all()

    _ = ConnectToken.invalidate_user_tokens(user_id)
    {:ok, count}
  end

  @spec authorized?(Message.t()) :: boolean()
  def authorized?(%Message{} = message) do
    private_chat?(message) and match?({:ok, _}, sender_identity(message))
  end

  @spec consume_start_link(Message.t()) :: link_result()
  def consume_start_link(%Message{} = message) do
    with :ok <- ensure_private_chat(message),
         {:ok, token} <- extract_start_token(message),
         {:ok, auth_token} <- consume_token(token),
         {:ok, _identity} <- link_identity(auth_token.user_id, message) do
      {:ok, :linked}
    end
  end

  defp consume_token(token) do
    case ConnectToken.consume(token) do
      {:ok, auth_token} -> {:ok, auth_token}
      {:error, :not_found} -> {:error, :invalid_token}
      {:error, :expired} -> {:error, :expired_token}
      {:error, :already_used} -> {:error, :already_used_token}
    end
  end

  defp link_identity(user_id, %Message{} = message) do
    Repo.transaction(fn ->
      with {:ok, _} <- ensure_user_not_already_linked(user_id, message.user_id),
           {:ok, identity} <- upsert_identity(user_id, message) do
        identity
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, _identity} ->
        Logger.info("Telegram account linked",
          user_id: user_id,
          telegram_user_id: message.user_id,
          chat_id: message.space_id
        )

        {:ok, :linked}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_user_not_already_linked(user_id, external_id) do
    query =
      from(ui in UserIdentity,
        where:
          ui.user_id == ^user_id and ui.channel == ^@channel and ui.external_id != ^external_id,
        select: ui.id,
        limit: 1
      )

    case Repo.one(query) do
      nil -> {:ok, :clear}
      _identity_id -> {:error, :user_already_linked}
    end
  end

  defp upsert_identity(user_id, %Message{} = message) do
    case sender_identity(message) do
      {:ok, %UserIdentity{user_id: ^user_id} = identity} ->
        identity
        |> Ecto.Changeset.change(%{
          display_name: message.user_display_name,
          space_id: message.space_id,
          metadata: build_metadata(message)
        })
        |> Repo.update()

      {:ok, %UserIdentity{}} ->
        {:error, :already_linked}

      {:error, :not_connected} ->
        %UserIdentity{}
        |> UserIdentity.changeset(%{
          user_id: user_id,
          channel: @channel,
          external_id: message.user_id,
          space_id: message.space_id,
          display_name: message.user_display_name,
          metadata: build_metadata(message)
        })
        |> Repo.insert()
    end
  end

  defp sender_identity(%Message{} = message) do
    exact_query =
      from(ui in UserIdentity,
        where:
          ui.channel == ^@channel and ui.external_id == ^message.user_id and
            ui.space_id == ^message.space_id,
        limit: 1
      )

    case Repo.one(exact_query) do
      %UserIdentity{} = identity ->
        {:ok, identity}

      nil ->
        fallback_query =
          from(ui in UserIdentity,
            where:
              ui.channel == ^@channel and ui.external_id == ^message.user_id and
                is_nil(ui.space_id),
            limit: 1
          )

        case Repo.one(fallback_query) do
          %UserIdentity{} = identity ->
            identity
            |> Ecto.Changeset.change(%{space_id: message.space_id})
            |> Repo.update!()

            {:ok, %{identity | space_id: message.space_id}}

          nil ->
            {:error, :not_connected}
        end
    end
  end

  defp ensure_private_chat(message) do
    if private_chat?(message) do
      :ok
    else
      {:error, :not_private_chat}
    end
  end

  defp private_chat?(%Message{} = message) do
    message.metadata["chat_type"] == "private"
  end

  defp extract_start_token(%Message{slash_command: "/start", argument_text: argument_text}) do
    token = argument_text |> to_string() |> String.trim()

    if token == "" do
      {:error, :missing_token}
    else
      {:ok, token}
    end
  end

  defp extract_start_token(_message), do: {:error, :missing_token}

  defp build_metadata(message) do
    %{
      "chat_type" => message.metadata["chat_type"],
      "chat_title" => message.metadata["chat_title"],
      "linked_via" => "telegram_start"
    }
  end

  defp get_bot_identity(bot_token) when is_binary(bot_token) and bot_token != "" do
    Client.get_me(bot_token)
  end

  defp get_bot_identity(_bot_token), do: Client.get_me()
end
