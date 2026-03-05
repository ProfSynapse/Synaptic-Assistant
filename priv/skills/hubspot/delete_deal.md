---
name: "hubspot.delete_deal"
description: "Delete (archive) a deal in HubSpot CRM."
handler: "Assistant.Skills.HubSpot.Deals.Delete"
confirm: true
tags:
  - hubspot
  - crm
  - deals
  - write
  - delete
parameters:
  - name: "id"
    type: "string"
    required: true
    description: "HubSpot deal ID"
---

# hubspot.delete_deal

Archive a deal in HubSpot CRM by its ID. This performs a soft delete
(archive) — the deal can be restored from HubSpot's recycling bin.

**This is a mutating action.** The assistant should confirm the deletion
with the user before executing this skill.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| id | string | yes | HubSpot deal ID |

## Response

Returns confirmation of the archived deal:

```
Deal 12345 has been archived successfully.
```

## Example

```
/hubspot.delete_deal --id 12345
```

## Usage Notes

- This archives the deal; it does not permanently delete it.
- Archived deals can be restored from HubSpot's recycling bin within 90 days.
- Returns an error if no deal exists with the given ID.
