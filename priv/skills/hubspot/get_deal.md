---
name: "hubspot.get_deal"
description: "Get a deal from HubSpot CRM by ID."
handler: "Assistant.Skills.HubSpot.Deals.Get"
tags:
  - hubspot
  - crm
  - deals
  - read
parameters:
  - name: "id"
    type: "string"
    required: true
    description: "HubSpot deal ID"
---

# hubspot.get_deal

Retrieve a single deal from HubSpot CRM by its ID. Returns the deal's
name, amount, close date, stage, pipeline, and description.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| id | string | yes | HubSpot deal ID |

## Response

Returns the deal details:

```
ID: 12345
Deal Name: Acme Corp Enterprise License
Amount: 50000
Close Date: 2026-06-30
Stage: appointmentscheduled
Pipeline: default
```

## Example

```
/hubspot.get_deal --id 12345
```

## Usage Notes

- Returns an error if no deal exists with the given ID.
