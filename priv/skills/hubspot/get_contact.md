---
name: "hubspot.get_contact"
description: "Get a contact from HubSpot CRM by ID."
handler: "Assistant.Skills.HubSpot.Contacts.Get"
tags:
  - hubspot
  - crm
  - contacts
  - read
parameters:
  - name: "id"
    type: "string"
    required: true
    description: "HubSpot contact ID"
---

# hubspot.get_contact

Retrieve a single contact from HubSpot CRM by its ID. Returns the contact's
email, name, phone, and company fields.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| id | string | yes | HubSpot contact ID |

## Response

Returns the contact details:

```
ID: 123
Email: jane@example.com
First Name: Jane
Last Name: Doe
Phone: +1-555-0100
Company: Acme Corp
```

## Example

```
/hubspot.get_contact --id 123
```

## Usage Notes

- Returns an error if no contact exists with the given ID.
- Use `hubspot.search_contacts` to find a contact's ID by email or name.
