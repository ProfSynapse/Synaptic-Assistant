---
name: "hubspot.create_company"
description: "Create a new company in HubSpot CRM."
handler: "Assistant.Skills.HubSpot.Companies.Create"
confirm: true
tags:
  - hubspot
  - crm
  - companies
  - write
parameters:
  - name: "name"
    type: "string"
    required: true
    description: "Company name"
  - name: "domain"
    type: "string"
    required: false
    description: "Company domain (e.g. example.com)"
  - name: "website"
    type: "string"
    required: false
    description: "Company website URL"
  - name: "industry"
    type: "string"
    required: false
    description: "Industry the company operates in"
  - name: "description"
    type: "string"
    required: false
    description: "Brief description of the company"
  - name: "properties"
    type: "string"
    required: false
    description: "Additional properties as JSON (e.g. '{\"numberofemployees\": \"50\"}')"
---

# hubspot.create_company

Create a new company in HubSpot CRM. Requires the company name; other fields
are optional. Arbitrary HubSpot properties can be passed as JSON via `--properties`.

**This is a mutating action.** The assistant should confirm the company details
with the user before executing this skill.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| name | string | yes | Company name |
| domain | string | no | Company domain (e.g. example.com) |
| website | string | no | Company website URL |
| industry | string | no | Industry the company operates in |
| description | string | no | Brief description of the company |
| properties | string | no | Additional properties as JSON |

## Response

Returns confirmation with the created company details:

```
Company created successfully.

ID: 12345
Name: Acme Corp
Domain: acme.com
Website: https://acme.com
Industry: Technology
```

## Example

```
/hubspot.create_company --name "Acme Corp" --domain "acme.com" --industry "Technology"
```
