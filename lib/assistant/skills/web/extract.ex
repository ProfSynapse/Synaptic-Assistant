defmodule Assistant.Skills.Web.Extract do
  @moduledoc """
  Skill handler for extracting readable content from a web page.
  """

  @behaviour Assistant.Skills.Handler

  alias Assistant.Skills.Web.Fetch

  @impl true
  def execute(flags, context), do: Fetch.execute(flags, context)
end
