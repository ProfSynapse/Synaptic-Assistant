---
name: "hubspot.get_company"
description: "Get a company from HubSpot CRM by ID."
handler: "Assistant.Skills.HubSpot.Companies.Get"
tags:
  - hubspot
  - crm
  - companies
  - read
parameters:
  - name: "id"
    type: "string"
    required: true
    description: "HubSpot company ID"
---

# hubspot.get_company

Retrieve a single company from HubSpot CRM by its ID. Returns company details
including name, domain, website, industry, and description.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| id | string | yes | HubSpot company ID |

## Response

Returns the company details:

```
ID: 12345
Name: Acme Corp
Domain: acme.com
Website: https://acme.com
Industry: Technology
Description: Leading technology company
```

## Example

```
/hubspot.get_company --id "12345"
```
