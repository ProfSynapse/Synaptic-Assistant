defmodule Assistant.ConnectedDrives do
  @moduledoc """
  Context module for managing user-connected Google Drives.
  """

  import Ecto.Query
  alias Assistant.Repo
  alias Assistant.Schemas.ConnectedDrive

  @doc "List all connected drives for a user, personal first, then by name."
  @spec list_for_user(String.t()) :: [ConnectedDrive.t()]
  def list_for_user(user_id) do
    ConnectedDrive
    |> where(user_id: ^user_id)
    |> order_by([d], asc: d.drive_type, asc: d.drive_name)
    |> Repo.all()
  end

  @doc "List only enabled drives for a user (for skill execution)."
  @spec enabled_for_user(String.t()) :: [ConnectedDrive.t()]
  def enabled_for_user(user_id) do
    ConnectedDrive
    |> where(user_id: ^user_id, enabled: true)
    |> Repo.all()
  end

  @doc "Connect a drive for a user (upsert by user_id + drive_id)."
  @spec connect(String.t(), map()) :: {:ok, ConnectedDrive.t()} | {:error, Ecto.Changeset.t()}
  def connect(user_id, attrs) do
    attrs = Map.put(attrs, :user_id, user_id)

    %ConnectedDrive{}
    |> ConnectedDrive.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:drive_name, :enabled, :updated_at]},
      conflict_target: conflict_target(attrs)
    )
  end

  @doc "Toggle a connected drive's enabled state."
  @spec toggle(String.t(), boolean()) :: {:ok, ConnectedDrive.t()} | {:error, term()}
  def toggle(drive_row_id, enabled?) do
    case Repo.get(ConnectedDrive, drive_row_id) do
      nil -> {:error, :not_found}
      drive -> drive |> Ecto.Changeset.change(enabled: enabled?) |> Repo.update()
    end
  end

  @doc "Disconnect (delete) a drive."
  @spec disconnect(String.t()) :: {:ok, ConnectedDrive.t()} | {:error, term()}
  def disconnect(drive_row_id) do
    case Repo.get(ConnectedDrive, drive_row_id) do
      nil -> {:error, :not_found}
      drive -> Repo.delete(drive)
    end
  end

  @doc "Idempotently ensure the personal 'My Drive' entry exists for a user."
  @spec ensure_personal_drive(String.t()) ::
          {:ok, ConnectedDrive.t()} | {:error, Ecto.Changeset.t()}
  def ensure_personal_drive(user_id) do
    connect(user_id, %{drive_id: nil, drive_name: "My Drive", drive_type: "personal"})
  end

  defp conflict_target(%{drive_type: "personal"}),
    do: {:unsafe_fragment, "(user_id) WHERE drive_id IS NULL"}

  defp conflict_target(_),
    do: {:unsafe_fragment, "(user_id, drive_id) WHERE drive_id IS NOT NULL"}
end
