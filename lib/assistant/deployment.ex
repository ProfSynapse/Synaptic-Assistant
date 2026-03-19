defmodule Assistant.Deployment do
  @moduledoc false

  def mode do
    Application.get_env(:assistant, :deployment_mode, :cloud)
  end

  def cloud?, do: mode() == :cloud
  def self_hosted?, do: mode() == :self_hosted
end
