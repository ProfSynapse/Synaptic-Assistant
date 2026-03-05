# lib/assistant/skills/hubspot/contacts/create.ex — Handler for hubspot.create_contact skill.
#
# Creates a new contact in HubSpot CRM. Requires an email address; optionally
# accepts first_name, last_name, phone, company, and additional JSON properties.
#
# Related files:
#   - lib/assistant/integrations/hubspot/client.ex (API client)
#   - lib/assistant/skills/hubspot/helpers.ex (shared helpers)
#   - priv/skills/hubspot/create_contact.md (skill definition)

defmodule Assistant.Skills.HubSpot.Contacts.Create do
  @behaviour Assistant.Skills.Handler

  require Logger

  alias Assistant.Skills.HubSpot.Helpers
  alias Assistant.Skills.Result

  @contact_fields [
    {"Email", "email"},
    {"First Name", "firstname"},
    {"Last Name", "lastname"},
    {"Phone", "phone"},
    {"Company", "company"}
  ]

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
    email = Map.get(flags, "email")

    if is_nil(email) || email == "" do
      {:ok, %Result{status: :error, content: "Missing required parameter: --email."}}
    else
      case Helpers.parse_properties_json(Map.get(flags, "properties")) do
        {:error, message} ->
          {:ok, %Result{status: :error, content: message}}

        {:ok, extra_props} ->
          properties =
            %{"email" => email}
            |> Helpers.maybe_put("firstname", Map.get(flags, "first_name"))
            |> Helpers.maybe_put("lastname", Map.get(flags, "last_name"))
            |> Helpers.maybe_put("phone", Map.get(flags, "phone"))
            |> Helpers.maybe_put("company", Map.get(flags, "company"))
            |> Map.merge(extra_props)

          case hubspot.create_contact(api_key, properties) do
            {:ok, contact} ->
              formatted = Helpers.format_object(contact, @contact_fields)

              Logger.info("HubSpot contact created", contact_id: contact[:id])

              {:ok,
               %Result{
                 status: :ok,
                 content: "Contact created successfully.\n\n#{formatted}",
                 side_effects: [:hubspot_contact_created],
                 metadata: %{contact_id: contact[:id]}
               }}

            {:error, {:api_error, 409, _}} = error ->
              Helpers.handle_error(error, "contact", "email")

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
