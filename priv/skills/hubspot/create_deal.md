---
name: "hubspot.create_deal"
description: "Create a new deal in HubSpot CRM."
handler: "Assistant.Skills.HubSpot.Deals.Create"
confirm: true
tags:
  - hubspot
  - crm
  - deals
  - write
parameters:
  - name: "dealname"
    type: "string"
    required: true
    description: "Deal name"
  - name: "pipeline"
    type: "string"
    required: false
    description: "Pipeline name or ID"
  - name: "dealstage"
    type: "string"
    required: false
    description: "Deal stage name or ID"
  - name: "amount"
    type: "string"
    required: false
    description: "Deal amount (monetary value)"
  - name: "closedate"
    type: "string"
    required: false
    description: "Expected close date (YYYY-MM-DD)"
  - name: "description"
    type: "string"
    required: false
    description: "Deal description"
  - name: "properties"
    type: "string"
    required: false
    description: "Additional properties as JSON (e.g. '{\"hs_priority\": \"high\"}')"
---

# hubspot.create_deal

Create a new deal in HubSpot CRM. Requires a deal name. Optionally set
pipeline, stage, amount, close date, description, or arbitrary properties.

**This is a mutating action.** The assistant should confirm the deal details
with the user before executing this skill.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| dealname | string | yes | Deal name |
| pipeline | string | no | Pipeline name or ID |
| dealstage | string | no | Deal stage name or ID |
| amount | string | no | Deal amount (monetary value) |
| closedate | string | no | Expected close date (YYYY-MM-DD) |
| description | string | no | Deal description |
| properties | string | no | Additional properties as JSON |

## Response

Returns the created deal with its HubSpot ID and properties:

```
Deal created successfully.

ID: 12345
Deal Name: Acme Corp Enterprise License
Amount: 50000
Close Date: 2026-06-30
Stage: appointmentscheduled
Pipeline: default
```

## Example

```
/hubspot.create_deal --dealname "Acme Corp Enterprise License" --amount 50000 --closedate "2026-06-30" --dealstage "appointmentscheduled"
```

## Usage Notes

- The `--dealname` parameter is required; all others are optional.
- The `--properties` flag accepts a JSON object for any HubSpot deal property not covered by the named flags.
- The deal is created immediately in HubSpot; there is no draft mechanism.
