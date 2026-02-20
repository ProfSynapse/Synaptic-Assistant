defmodule Assistant.ProfileSettings do
  @moduledoc """
  File-backed profile/account settings used by the settings UI.
  """

  @default_path "config/profile_settings.json"

  @spec get_profile() :: map()
  def get_profile do
    path = profile_path()

    if File.exists?(path) do
      with {:ok, content} <- File.read(path),
           {:ok, decoded} <- Jason.decode(content),
           profile when is_map(profile) <- decoded["profile"] do
        sanitize_profile(profile)
      else
        _ -> default_profile()
      end
    else
      default_profile()
    end
  rescue
    _ -> default_profile()
  end

  @spec save_profile(map()) :: :ok | {:error, term()}
  def save_profile(params) when is_map(params) do
    profile = sanitize_profile(params)
    path = profile_path()
    File.mkdir_p!(Path.dirname(path))
    payload = Jason.encode_to_iodata!(%{"profile" => profile}, pretty: true)
    File.write(path, payload)
  rescue
    exception ->
      {:error, exception}
  end

  defp sanitize_profile(params) do
    %{
      "display_name" =>
        string_value(Map.get(params, "display_name") || Map.get(params, :display_name)),
      "email" => string_value(Map.get(params, "email") || Map.get(params, :email)),
      "timezone" => string_value(Map.get(params, "timezone") || Map.get(params, :timezone), "UTC")
    }
  end

  defp default_profile do
    %{"display_name" => "", "email" => "", "timezone" => "UTC"}
  end

  defp string_value(value, default \\ "") do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> default
      v -> v
    end
  end

  defp profile_path do
    Application.get_env(:assistant, :profile_settings_path, @default_path)
  end
end
