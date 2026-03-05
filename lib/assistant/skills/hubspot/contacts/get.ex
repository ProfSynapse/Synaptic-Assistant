# lib/assistant/skills/hubspot/contacts/get.ex — Handler for hubspot.get_contact skill.
#
# Retrieves a single contact from HubSpot CRM by ID and formats the result
# with standard contact display fields.
#
# Related files:
#   - lib/assistant/integrations/hubspot/client.ex (API client)
#   - lib/assistant/skills/hubspot/helpers.ex (shared helpers)
#   - priv/skills/hubspot/get_contact.md (skill definition)

defmodule Assistant.Skills.HubSpot.Contacts.Get do
  @moduledoc false
  @behaviour Assistant.Skills.Handler

  alias Assistant.Skills.HubSpot.Helpers
  alias Assistant.Skills.Result

  @impl true
  def execute(flags, context) do
    case Map.get(context.integrations, :hubspot) do
      nil ->
        Helpers.integration_not_configured()

      hubspot ->
        case Helpers.resolve_api_key() do
          nil -> Helpers.api_key_not_found()
          api_key -> do_execute(hubspot, api_key, flags)
        end
    end
  end

  defp do_execute(hubspot, api_key, flags) do
    id = Map.get(flags, "id")

    cond do
      is_nil(id) || id == "" ->
        {:ok, %Result{status: :error, content: "Missing required parameter: --id."}}

      not String.match?(id, ~r/^\d+$/) ->
        {:ok, %Result{status: :error, content: "Invalid --id: must be a numeric HubSpot ID."}}

      true ->
        case hubspot.get_contact(api_key, id) do
          {:ok, contact} ->
            formatted = Helpers.format_object(contact, Helpers.contact_fields())
            {:ok, %Result{status: :ok, content: formatted}}

          {:error, {:api_error, 404, _}} = error ->
            Helpers.handle_error(error, "contact", id)

          {:error, {:api_error, 401, _}} = error ->
            Helpers.handle_error(error)

          {:error, {:api_error, 429, _}} = error ->
            Helpers.handle_error(error)

          error ->
            Helpers.handle_error(error)
        end
    end
  end
end
