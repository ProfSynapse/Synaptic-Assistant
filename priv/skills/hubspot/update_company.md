---
name: "hubspot.update_company"
description: "Update a company in HubSpot CRM."
handler: "Assistant.Skills.HubSpot.Companies.Update"
confirm: true
tags:
  - hubspot
  - crm
  - companies
  - write
parameters:
  - name: "id"
    type: "string"
    required: true
    description: "HubSpot company ID"
  - name: "name"
    type: "string"
    required: false
    description: "Updated company name"
  - name: "domain"
    type: "string"
    required: false
    description: "Updated company domain"
  - name: "website"
    type: "string"
    required: false
    description: "Updated company website URL"
  - name: "industry"
    type: "string"
    required: false
    description: "Updated industry"
  - name: "description"
    type: "string"
    required: false
    description: "Updated company description"
  - name: "properties"
    type: "string"
    required: false
    description: "Additional properties as JSON (e.g. '{\"numberofemployees\": \"100\"}')"
---

# hubspot.update_company

Update an existing company in HubSpot CRM. Requires the company ID; at least
one property must be provided to update.

**This is a mutating action.** The assistant should confirm the changes with
the user before executing this skill.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| id | string | yes | HubSpot company ID |
| name | string | no | Updated company name |
| domain | string | no | Updated company domain |
| website | string | no | Updated company website URL |
| industry | string | no | Updated industry |
| description | string | no | Updated company description |
| properties | string | no | Additional properties as JSON |

## Response

Returns confirmation with the updated company details:

```
Company updated successfully.

ID: 12345
Name: Acme Corp
Domain: acme.com
Website: https://acme.com
Industry: SaaS
```

## Example

```
/hubspot.update_company --id "12345" --industry "SaaS" --website "https://acme.io"
```
