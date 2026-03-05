---
name: "hubspot.create_contact"
description: "Create a new contact in HubSpot CRM."
handler: "Assistant.Skills.HubSpot.Contacts.Create"
confirm: true
tags:
  - hubspot
  - crm
  - contacts
  - write
parameters:
  - name: "email"
    type: "string"
    required: true
    description: "Contact email address"
  - name: "first_name"
    type: "string"
    required: false
    description: "Contact first name"
  - name: "last_name"
    type: "string"
    required: false
    description: "Contact last name"
  - name: "phone"
    type: "string"
    required: false
    description: "Phone number"
  - name: "company"
    type: "string"
    required: false
    description: "Company name"
  - name: "properties"
    type: "string"
    required: false
    description: "Additional properties as JSON (e.g. '{\"jobtitle\": \"CTO\"}')"
---

# hubspot.create_contact

Create a new contact in HubSpot CRM. Requires an email address. Optionally
set first name, last name, phone, company, and additional custom properties.

**This is a mutating action.** The assistant should confirm the contact details
with the user before executing this skill.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| email | string | yes | Contact email address |
| first_name | string | no | Contact first name |
| last_name | string | no | Contact last name |
| phone | string | no | Phone number |
| company | string | no | Company name |
| properties | string | no | Additional properties as JSON |

## Response

Returns confirmation with the created contact details:

```
Contact created successfully.

ID: 123
Email: jane@example.com
First Name: Jane
Last Name: Doe
Company: Acme Corp
```

## Example

```
/hubspot.create_contact --email jane@example.com --first_name Jane --last_name Doe --company "Acme Corp"
```

## Usage Notes

- A contact with the same email cannot be created twice (returns a conflict error).
- The `--properties` flag accepts a JSON object for setting any HubSpot contact property not covered by the named flags.
