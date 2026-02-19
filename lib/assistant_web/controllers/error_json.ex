# lib/assistant_web/controllers/error_json.ex — JSON error responses.
#
# Renders error responses for the API. Called by Phoenix when an error
# occurs during request processing.

defmodule AssistantWeb.ErrorJSON do
  @moduledoc """
  Renders JSON error responses.

  Called via the `:formats` option in `AssistantWeb.Endpoint`.
  """

  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end
