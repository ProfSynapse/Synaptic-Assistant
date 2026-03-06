defmodule Assistant.Accounts.SettingsUserAllowlistEntry do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "settings_user_allowlist_entries" do
    field :email, :string
    field :full_name, :string
    field :active, :boolean, default: true
    field :is_admin, :boolean, default: false
    field :scopes, {:array, :string}, default: []
    field :notes, :string

    belongs_to :created_by_settings_user, Assistant.Accounts.SettingsUser
    belongs_to :updated_by_settings_user, Assistant.Accounts.SettingsUser

    timestamps(type: :utc_datetime)
  end

  def changeset(entry, attrs, opts \\ []) do
    allowed_scopes = Keyword.get(opts, :allowed_scopes, [])

    entry
    |> cast(attrs, [:email, :full_name, :active, :is_admin, :scopes, :notes])
    |> update_change(:email, &normalize_email/1)
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
      message: "must have the @ sign and no spaces"
    )
    |> validate_length(:email, max: 160)
    |> validate_length(:notes, max: 1000)
    |> normalize_scopes(allowed_scopes)
    |> unique_constraint(:email)
  end

  defp normalize_email(email) when is_binary(email) do
    email
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_email(email), do: email

  defp normalize_scopes(changeset, allowed_scopes) do
    scopes =
      changeset
      |> get_field(:scopes, [])
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.filter(&(&1 in allowed_scopes))

    put_change(changeset, :scopes, scopes)
  end
end
