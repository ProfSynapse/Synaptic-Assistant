---
name: "calendar.list"
description: "List Google Calendar events with date and time range filtering."
handler: "Assistant.Skills.Calendar.List"
tags:
  - calendar
  - read
  - events
---

# calendar.list

List events from a Google Calendar. Supports filtering by a specific date,
a custom date range, result limit, and calendar ID.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| date | string | no | List events on a specific date (YYYY-MM-DD) |
| from | string | no | Start of date range (RFC 3339 or "YYYY-MM-DD HH:MM") |
| to | string | no | End of date range (RFC 3339 or "YYYY-MM-DD HH:MM") |
| limit | integer | no | Max events to return (default 10, max 50) |
| calendar | string | no | Calendar ID (default "primary") |

## Response

Returns a formatted list:

```
Found 3 event(s):
- Team standup | 2026-02-19T09:00:00Z - 2026-02-19T09:30:00Z
- Lunch with Alex | 2026-02-19T12:00:00Z - 2026-02-19T13:00:00Z | Location: Cafe Roma
- Sprint review | 2026-02-19T15:00:00Z - 2026-02-19T16:00:00Z
```

Returns "No events found." when no results match.

## Usage Notes

- Use `--date` for a single day's events. It sets time_min to start of day and time_max to end of day (UTC).
- Use `--from` and `--to` for custom ranges. Accepts RFC 3339 or "YYYY-MM-DD HH:MM" format.
- If no date parameters are provided, returns upcoming events without time bounds.
- Recurring events are expanded into individual occurrences.
