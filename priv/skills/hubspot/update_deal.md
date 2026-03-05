---
name: "hubspot.update_deal"
description: "Update an existing deal in HubSpot CRM."
handler: "Assistant.Skills.HubSpot.Deals.Update"
confirm: true
tags:
  - hubspot
  - crm
  - deals
  - write
parameters:
  - name: "id"
    type: "string"
    required: true
    description: "HubSpot deal ID"
  - name: "dealname"
    type: "string"
    required: false
    description: "New deal name"
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

# hubspot.update_deal

Update an existing deal in HubSpot CRM. Requires the deal ID and at least
one property to change.

**This is a mutating action.** The assistant should confirm the changes
with the user before executing this skill.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| id | string | yes | HubSpot deal ID |
| dealname | string | no | New deal name |
| pipeline | string | no | Pipeline name or ID |
| dealstage | string | no | Deal stage name or ID |
| amount | string | no | Deal amount (monetary value) |
| closedate | string | no | Expected close date (YYYY-MM-DD) |
| description | string | no | Deal description |
| properties | string | no | Additional properties as JSON |

## Response

Returns the updated deal:

```
Deal updated successfully.

ID: 12345
Deal Name: Acme Corp Enterprise License
Amount: 75000
Close Date: 2026-06-30
Stage: contractsent
Pipeline: default
```

## Example

```
/hubspot.update_deal --id 12345 --amount 75000 --dealstage "contractsent"
```

## Usage Notes

- At least one property must be provided in addition to `--id`.
- Only the specified properties are changed; others remain unchanged.
- The `--properties` flag accepts a JSON object for any property not covered by named flags.
