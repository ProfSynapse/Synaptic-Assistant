---
name: "calendar.create"
description: "Create a new Google Calendar event."
handler: "Assistant.Skills.Calendar.Create"
confirm: true
requires_approval: true
tags:
  - calendar
  - write
  - events
parameters:
  - name: "title"
    type: "string"
    required: true
    description: "Event title"
  - name: "start"
    type: "string"
    required: true
    description: "Start time (RFC 3339 or \"YYYY-MM-DD HH:MM\")"
  - name: "end"
    type: "string"
    required: true
    description: "End time (RFC 3339 or \"YYYY-MM-DD HH:MM\")"
  - name: "description"
    type: "string"
    required: false
    description: "Event description"
  - name: "location"
    type: "string"
    required: false
    description: "Event location"
  - name: "attendees"
    type: "string"
    required: false
    description: "Comma-separated email addresses"
  - name: "calendar"
    type: "string"
    required: false
    description: "Calendar ID (default \"primary\")"
---

# calendar.create

Create a new event on a Google Calendar. Requires a title, start time, and
end time. Optionally accepts a description, location, attendees, and
calendar ID.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| title | string | yes | Event title |
| start | string | yes | Start time (RFC 3339 or "YYYY-MM-DD HH:MM") |
| end | string | yes | End time (RFC 3339 or "YYYY-MM-DD HH:MM") |
| description | string | no | Event description |
| location | string | no | Event location |
| attendees | string | no | Comma-separated email addresses |
| calendar | string | no | Calendar ID (default "primary") |

## Response

Returns a confirmation:

```
Event created successfully.
ID: abc123def456
Title: Team standup
Link: https://calendar.google.com/event?eid=abc123
```

## Usage Notes

- Times in "YYYY-MM-DD HH:MM" format are assumed UTC and normalized to RFC 3339.
- Attendees are specified as a comma-separated list of email addresses.
- This is a mutating skill — the assistant will confirm before executing.
