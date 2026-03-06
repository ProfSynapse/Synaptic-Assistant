# lib/assistant/skills/hubspot/contacts/update.ex — Handler for hubspot.update_contact skill.
#
# Updates an existing contact in HubSpot CRM by ID. Accepts any combination
# of contact fields plus additional JSON properties. At least one field
# besides --id must be provided.
#
# Related files:
#   - lib/assistant/integrations/hubspot/client.ex (API client)
#   - lib/assistant/skills/hubspot/helpers.ex (shared helpers)
#   - priv/skills/hubspot/update_contact.md (skill definition)

defmodule Assistant.Skills.HubSpot.Contacts.Update do
  @moduledoc false
  @behaviour Assistant.Skills.Handler

  require Logger

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
        case Helpers.parse_properties_json(Map.get(flags, "properties")) do
          {:error, message} ->
            {:ok, %Result{status: :error, content: message}}

          {:ok, extra_props} ->
            properties =
              %{}
              |> Helpers.maybe_put("email", Map.get(flags, "email"))
              |> Helpers.maybe_put("firstname", Map.get(flags, "first_name"))
              |> Helpers.maybe_put("lastname", Map.get(flags, "last_name"))
              |> Helpers.maybe_put("phone", Map.get(flags, "phone"))
              |> Helpers.maybe_put("company", Map.get(flags, "company"))
              |> Map.merge(extra_props)

            if properties == %{} do
              {:ok,
               %Result{
                 status: :error,
                 content:
                   "No fields to update. Provide at least one field (--email, --first_name, --last_name, --phone, --company, or --properties)."
               }}
            else
              case hubspot.update_contact(api_key, id, properties) do
                {:ok, contact} ->
                  formatted = Helpers.format_object(contact, Helpers.contact_fields())

                  Logger.info("HubSpot contact updated", contact_id: id)

                  {:ok,
                   %Result{
                     status: :ok,
                     content: "Contact updated successfully.\n\n#{formatted}",
                     side_effects: [:hubspot_contact_updated],
                     metadata: %{contact_id: id}
                   }}

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
  end
end
