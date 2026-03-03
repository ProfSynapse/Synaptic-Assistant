---
name: "calendar.update"
description: "Update an existing Google Calendar event."
handler: "Assistant.Skills.Calendar.Update"
confirm: true
tags:
  - calendar
  - write
  - events
parameters:
  - name: "id"
    type: "string"
    required: true
    description: "Event ID to update"
  - name: "title"
    type: "string"
    required: false
    description: "New event title"
  - name: "start"
    type: "string"
    required: false
    description: "New start time (RFC 3339 or \"YYYY-MM-DD HH:MM\")"
  - name: "end"
    type: "string"
    required: false
    description: "New end time (RFC 3339 or \"YYYY-MM-DD HH:MM\")"
  - name: "description"
    type: "string"
    required: false
    description: "New event description"
  - name: "location"
    type: "string"
    required: false
    description: "New event location"
  - name: "attendees"
    type: "string"
    required: false
    description: "New comma-separated attendee emails (replaces existing)"
  - name: "calendar"
    type: "string"
    required: false
    description: "Calendar ID (default \"primary\")"
---

# calendar.update

Update an existing event on a Google Calendar. Requires the event ID.
Only provided fields are updated; omitted fields remain unchanged.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| id | string | yes | Event ID to update |
| title | string | no | New event title |
| start | string | no | New start time (RFC 3339 or "YYYY-MM-DD HH:MM") |
| end | string | no | New end time (RFC 3339 or "YYYY-MM-DD HH:MM") |
| description | string | no | New event description |
| location | string | no | New event location |
| attendees | string | no | New comma-separated attendee emails (replaces existing) |
| calendar | string | no | Calendar ID (default "primary") |

## Response

Returns a confirmation:

```
Event updated successfully.
ID: abc123def456
Title: Updated standup
```

## Usage Notes

- Only non-nil flags are sent in the update — omitted fields are not changed.
- Providing `--attendees` replaces the full attendee list (not additive).
- This is a mutating skill — the assistant will confirm before executing.
