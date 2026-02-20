# lib/assistant/integrations/google/calendar.ex — Google Calendar API wrapper.
#
# Thin wrapper around GoogleApi.Calendar.V3 that normalizes response structs
# into plain maps. All public functions accept an `access_token` as first
# parameter (per-user OAuth or service-account) to create a Tesla connection.
#
# Related files:
#   - lib/assistant/integrations/google/auth.ex (token provider)
#   - lib/assistant/skills/calendar/list.ex (consumer — calendar.list skill)
#   - lib/assistant/skills/calendar/create.ex (consumer — calendar.create skill)
#   - lib/assistant/skills/calendar/update.ex (consumer — calendar.update skill)

defmodule Assistant.Integrations.Google.Calendar do
  @moduledoc """
  Google Calendar API client wrapping `GoogleApi.Calendar.V3`.

  Provides high-level functions for listing, getting, creating, and updating
  events in Google Calendar. All public functions that make API calls accept
  an `access_token` string as the first parameter.

  All public functions return normalized plain maps rather than GoogleApi
  structs, making them easier to work with in skill handlers and tests.

  ## Usage

      # List upcoming events
      {:ok, events} = Calendar.list_events(token, "primary", time_min: "2026-02-18T00:00:00Z")

      # Get a single event
      {:ok, event} = Calendar.get_event(token, "event_id_123")

      # Create an event
      {:ok, event} = Calendar.create_event(token, %{
        summary: "Team standup",
        start: "2026-02-19T09:00:00Z",
        end: "2026-02-19T09:30:00Z"
      })

      # Update an event
      {:ok, event} = Calendar.update_event(token, "event_id_123", %{summary: "Updated title"})
  """

  require Logger

  alias GoogleApi.Calendar.V3.Api.Events
  alias GoogleApi.Calendar.V3.Connection
  alias GoogleApi.Calendar.V3.Model

  @doc """
  List events from a calendar.

  ## Parameters

    - `access_token` - OAuth2 access token string
    - `calendar_id` - Calendar identifier (default `"primary"`)
    - `opts` - Optional keyword list:
      - `:time_min` - Lower bound (RFC 3339 string)
      - `:time_max` - Upper bound (RFC 3339 string)
      - `:max_results` - Max events returned (default 10)
      - `:single_events` - Expand recurring events (default `true`)
      - `:order_by` - Sort order (default `"startTime"`)

  ## Returns

    - `{:ok, [normalized_event_map]}` on success
    - `{:error, term()}` on failure
  """
  @spec list_events(String.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_events(access_token, calendar_id \\ "primary", opts \\ []) do
    conn = Connection.new(access_token)

    api_opts =
      [
        maxResults: Keyword.get(opts, :max_results, 10),
        singleEvents: Keyword.get(opts, :single_events, true),
        orderBy: Keyword.get(opts, :order_by, "startTime")
      ]
      |> add_opt(:timeMin, Keyword.get(opts, :time_min))
      |> add_opt(:timeMax, Keyword.get(opts, :time_max))

    case Events.calendar_events_list(conn, calendar_id, api_opts) do
      {:ok, %Model.Events{items: items}} ->
        normalized = Enum.map(items || [], &normalize_event/1)
        {:ok, normalized}

      {:error, reason} ->
        Logger.warning("Calendar list_events failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Get a single event by ID.

  ## Parameters

    - `access_token` - OAuth2 access token string
    - `event_id` - The event identifier
    - `calendar_id` - Calendar identifier (default `"primary"`)

  ## Returns

    - `{:ok, normalized_event_map}` on success
    - `{:error, term()}` on failure
  """
  @spec get_event(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_event(access_token, event_id, calendar_id \\ "primary") do
    conn = Connection.new(access_token)

    case Events.calendar_events_get(conn, calendar_id, event_id) do
      {:ok, %Model.Event{} = event} ->
        {:ok, normalize_event(event)}

      {:error, reason} ->
        Logger.warning("Calendar get_event failed for #{event_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Create a new calendar event.

  ## Parameters

    - `access_token` - OAuth2 access token string
    - `event_params` - Map with event details:
      - `:summary` - Event title (required)
      - `:description` - Event description (optional)
      - `:location` - Event location (optional)
      - `:start` - Start time as RFC 3339 string (required)
      - `:end` - End time as RFC 3339 string (required)
      - `:attendees` - List of email strings (optional)
    - `calendar_id` - Calendar identifier (default `"primary"`)

  ## Returns

    - `{:ok, normalized_event_map}` on success
    - `{:error, term()}` on failure
  """
  @spec create_event(String.t(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def create_event(access_token, event_params, calendar_id \\ "primary") do
    conn = Connection.new(access_token)
    event_body = build_event_struct(event_params)

    case Events.calendar_events_insert(conn, calendar_id, body: event_body) do
      {:ok, %Model.Event{} = event} ->
        {:ok, normalize_event(event)}

      {:error, reason} ->
        Logger.warning("Calendar create_event failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Update an existing calendar event.

  Fetches the existing event first, then merges the provided updates onto it
  before sending the update request.

  ## Parameters

    - `access_token` - OAuth2 access token string
    - `event_id` - The event identifier
    - `event_params` - Map with fields to update (same shape as `create_event/3`)
    - `calendar_id` - Calendar identifier (default `"primary"`)

  ## Returns

    - `{:ok, normalized_event_map}` on success
    - `{:error, term()}` on failure
  """
  @spec update_event(String.t(), String.t(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def update_event(access_token, event_id, event_params, calendar_id \\ "primary") do
    conn = Connection.new(access_token)

    with {:ok, existing} <- fetch_raw_event(conn, calendar_id, event_id) do
      updated = merge_event_updates(existing, event_params)

      case Events.calendar_events_update(conn, calendar_id, event_id, body: updated) do
        {:ok, %Model.Event{} = event} ->
          {:ok, normalize_event(event)}

        {:error, reason} ->
          Logger.warning("Calendar update_event failed for #{event_id}: #{inspect(reason)}")

          {:error, reason}
      end
    end
  end

  # -- Private --

  defp fetch_raw_event(conn, calendar_id, event_id) do
    case Events.calendar_events_get(conn, calendar_id, event_id) do
      {:ok, %Model.Event{} = event} -> {:ok, event}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_event_struct(params) do
    %Model.Event{
      summary: Map.get(params, :summary),
      description: Map.get(params, :description),
      location: Map.get(params, :location),
      start: build_event_datetime(Map.get(params, :start)),
      end: build_event_datetime(Map.get(params, :end)),
      attendees: build_attendees(Map.get(params, :attendees))
    }
  end

  defp build_event_datetime(nil), do: nil

  defp build_event_datetime(datetime_string) when is_binary(datetime_string) do
    %Model.EventDateTime{
      dateTime: datetime_string,
      timeZone: "UTC"
    }
  end

  defp build_attendees(nil), do: nil
  defp build_attendees([]), do: nil

  defp build_attendees(emails) when is_list(emails) do
    Enum.map(emails, fn email -> %Model.EventAttendee{email: email} end)
  end

  defp merge_event_updates(existing, params) do
    existing
    |> maybe_update(:summary, Map.get(params, :summary))
    |> maybe_update(:description, Map.get(params, :description))
    |> maybe_update(:location, Map.get(params, :location))
    |> maybe_update_datetime(:start, Map.get(params, :start))
    |> maybe_update_datetime(:end, Map.get(params, :end))
    |> maybe_update_attendees(Map.get(params, :attendees))
  end

  defp maybe_update(event, _field, nil), do: event

  defp maybe_update(event, field, value) do
    Map.put(event, field, value)
  end

  defp maybe_update_datetime(event, _field, nil), do: event

  defp maybe_update_datetime(event, field, datetime_string) do
    Map.put(event, field, build_event_datetime(datetime_string))
  end

  defp maybe_update_attendees(event, nil), do: event

  defp maybe_update_attendees(event, emails) do
    %{event | attendees: build_attendees(emails)}
  end

  defp normalize_event(%Model.Event{} = event) do
    %{
      id: event.id,
      summary: event.summary,
      description: event.description,
      location: event.location,
      start: extract_datetime(event.start),
      end: extract_datetime(event.end),
      attendees: extract_attendee_emails(event.attendees),
      html_link: event.htmlLink,
      status: event.status
    }
  end

  defp extract_datetime(nil), do: nil

  defp extract_datetime(%Model.EventDateTime{} = edt) do
    edt.dateTime || edt.date
  end

  defp extract_attendee_emails(nil), do: []

  defp extract_attendee_emails(attendees) when is_list(attendees) do
    Enum.map(attendees, & &1.email)
  end

  defp add_opt(opts, _key, nil), do: opts
  defp add_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
