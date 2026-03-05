---
name: "hubspot.delete_contact"
description: "Archive (delete) a contact in HubSpot CRM."
handler: "Assistant.Skills.HubSpot.Contacts.Delete"
requires_approval: true
tags:
  - hubspot
  - crm
  - contacts
  - write
  - delete
parameters:
  - name: "id"
    type: "string"
    required: true
    description: "HubSpot contact ID to archive"
---

# hubspot.delete_contact

Archive (soft-delete) a contact in HubSpot CRM by ID. The contact is not
permanently deleted and can be restored from the HubSpot web UI.

**This is a destructive action.** The assistant should confirm the contact ID
with the user before executing this skill.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| id | string | yes | HubSpot contact ID to archive |

## Response

Returns confirmation of the archival:

```
Contact 123 has been archived successfully.

Note: Archived contacts can be restored from the HubSpot UI.
```

## Example

```
/hubspot.delete_contact --id 123
```

## Usage Notes

- This archives the contact (soft delete). It can be restored from HubSpot.
- Returns an error if no contact exists with the given ID.
