---
name: "hubspot.update_contact"
description: "Update an existing contact in HubSpot CRM."
handler: "Assistant.Skills.HubSpot.Contacts.Update"
confirm: true
tags:
  - hubspot
  - crm
  - contacts
  - write
parameters:
  - name: "id"
    type: "string"
    required: true
    description: "HubSpot contact ID"
  - name: "email"
    type: "string"
    required: false
    description: "New email address"
  - name: "first_name"
    type: "string"
    required: false
    description: "New first name"
  - name: "last_name"
    type: "string"
    required: false
    description: "New last name"
  - name: "phone"
    type: "string"
    required: false
    description: "New phone number"
  - name: "company"
    type: "string"
    required: false
    description: "New company name"
  - name: "properties"
    type: "string"
    required: false
    description: "Additional properties as JSON (e.g. '{\"jobtitle\": \"CTO\"}')"
---

# hubspot.update_contact

Update an existing contact in HubSpot CRM by ID. Provide any combination of
fields to update. At least one field must be provided besides the ID.

**This is a mutating action.** The assistant should confirm the changes with
the user before executing this skill.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| id | string | yes | HubSpot contact ID |
| email | string | no | New email address |
| first_name | string | no | New first name |
| last_name | string | no | New last name |
| phone | string | no | New phone number |
| company | string | no | New company name |
| properties | string | no | Additional properties as JSON |

## Response

Returns the updated contact details:

```
Contact updated successfully.

ID: 123
Email: jane@newdomain.com
First Name: Jane
Last Name: Doe
Phone: +1-555-0200
Company: New Corp
```

## Example

```
/hubspot.update_contact --id 123 --phone "+1-555-0200" --company "New Corp"
```

## Usage Notes

- Only the provided fields are updated; omitted fields remain unchanged.
- Returns an error if no contact exists with the given ID.
