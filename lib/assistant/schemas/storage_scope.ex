defmodule Assistant.Schemas.StorageScope do
  @moduledoc """
  Provider-neutral storage access scope for a source, folder-like node, or file.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @providers ~w(google_drive dropbox microsoft box)
  @scope_types ~w(source container file)
  @scope_effects ~w(include exclude)
  @access_levels ~w(read_only read_write)
  @node_types ~w(source container file link)
  @file_kinds ~w(doc sheet slides pdf image file)

  schema "storage_scopes" do
    field :provider, :string
    field :source_id, :string
    field :node_id, :string
    field :parent_node_id, :string
    field :node_type, :string
    field :scope_type, :string, default: "container"
    field :scope_effect, :string, default: "include"
    field :access_level, :string, default: "read_only"
    field :label, :string
    field :file_kind, :string
    field :mime_type, :string
    field :provider_metadata, :map, default: %{}

    belongs_to :user, Assistant.Schemas.User

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :provider, :source_id, :node_type, :scope_type, :label]
  @optional_fields [
    :node_id,
    :parent_node_id,
    :scope_effect,
    :access_level,
    :file_kind,
    :mime_type,
    :provider_metadata
  ]

  def changeset(scope, attrs) do
    scope
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:provider, @providers)
    |> validate_inclusion(:scope_type, @scope_types)
    |> validate_inclusion(:scope_effect, @scope_effects)
    |> validate_inclusion(:access_level, @access_levels)
    |> validate_inclusion(:node_type, @node_types)
    |> validate_file_kind()
    |> validate_node_shape()
    |> unique_constraint([:user_id, :provider, :source_id, :scope_type],
      name: :storage_scopes_source_unique,
      message: "source scope already exists"
    )
    |> unique_constraint([:user_id, :provider, :source_id, :node_id, :scope_type],
      name: :storage_scopes_node_unique,
      message: "node scope already exists"
    )
  end

  defp validate_file_kind(changeset) do
    case get_field(changeset, :file_kind) do
      nil -> changeset
      kind when kind in @file_kinds -> changeset
      _ -> add_error(changeset, :file_kind, "is invalid")
    end
  end

  defp validate_node_shape(changeset) do
    scope_type = get_field(changeset, :scope_type)
    node_id = get_field(changeset, :node_id)

    case scope_type do
      "source" ->
        changeset
        |> ensure_nil(:node_id, "must be blank for source scopes")
        |> ensure_nil(:parent_node_id, "must be blank for source scopes")
        |> validate_change(:node_type, fn :node_type, value ->
          if value == "source", do: [], else: [node_type: "must be source for source scopes"]
        end)

      "container" ->
        changeset
        |> validate_required([:node_id])
        |> validate_change(:node_type, fn :node_type, value ->
          if value == "container",
            do: [],
            else: [node_type: "must be container for container scopes"]
        end)

      "file" ->
        changeset
        |> validate_required([:node_id])
        |> validate_change(:node_type, fn :node_type, value ->
          if value == "file", do: [], else: [node_type: "must be file for file scopes"]
        end)

      _ ->
        if is_nil(node_id), do: add_error(changeset, :node_id, "is required"), else: changeset
    end
  end

  defp ensure_nil(changeset, field, message) do
    case get_field(changeset, field) do
      nil -> changeset
      "" -> changeset
      _ -> add_error(changeset, field, message)
    end
  end
end
