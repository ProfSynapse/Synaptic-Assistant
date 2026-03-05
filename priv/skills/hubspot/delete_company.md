---
name: "hubspot.delete_company"
description: "Delete (archive) a company in HubSpot CRM."
handler: "Assistant.Skills.HubSpot.Companies.Delete"
requires_approval: true
tags:
  - hubspot
  - crm
  - companies
  - write
  - delete
parameters:
  - name: "id"
    type: "string"
    required: true
    description: "HubSpot company ID"
---

# hubspot.delete_company

Archive a company in HubSpot CRM. The company is soft-deleted and can be
restored from the HubSpot recycling bin.

**This is a mutating action.** The assistant should confirm the deletion with
the user before executing this skill.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| id | string | yes | HubSpot company ID |

## Response

Returns confirmation of the archive:

```
Company 12345 has been archived. It can be restored from the HubSpot recycling bin.
```

## Example

```
/hubspot.delete_company --id "12345"
```

## Usage Notes

- This archives the company rather than permanently deleting it.
- Archived companies can be restored from the HubSpot UI.
