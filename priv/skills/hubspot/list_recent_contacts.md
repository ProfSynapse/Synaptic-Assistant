---
name: "hubspot.list_recent_contacts"
description: "List recently created or updated contacts in HubSpot CRM."
handler: "Assistant.Skills.HubSpot.Contacts.ListRecent"
tags:
  - hubspot
  - crm
  - contacts
  - read
  - list
parameters:
  - name: "limit"
    type: "string"
    required: false
    description: "Maximum contacts to return (default 10, max 50)"
---

# hubspot.list_recent_contacts

List the most recently created or updated contacts in HubSpot CRM.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| limit | string | no | Maximum contacts to return (default 10, max 50) |

## Response

Returns a list of recent contacts:

```
Found 3 contacts:

ID: 789
Email: alice@example.com
First Name: Alice
Last Name: Johnson

---

ID: 456
Email: bob@example.com
First Name: Bob
Last Name: Williams

---

ID: 123
Email: carol@example.com
First Name: Carol
Last Name: Davis
```

## Example

```
/hubspot.list_recent_contacts
/hubspot.list_recent_contacts --limit 20
```

## Usage Notes

- Returns contacts ordered by most recently modified.
- Default limit is 10; maximum is 50.
