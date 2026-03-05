---
name: "hubspot.search_companies"
description: "Search for companies in HubSpot CRM."
handler: "Assistant.Skills.HubSpot.Companies.Search"
tags:
  - hubspot
  - crm
  - companies
  - read
  - search
parameters:
  - name: "query"
    type: "string"
    required: true
    description: "Search term"
  - name: "search_by"
    type: "string"
    required: false
    description: "Property to search by: 'name' (default) or 'domain'"
  - name: "limit"
    type: "string"
    required: false
    description: "Maximum number of results (default 10, max 50)"
---

# hubspot.search_companies

Search for companies in HubSpot CRM by name or domain. By default, searches
by company name using a contains-token match. Domain searches use exact match.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| query | string | yes | Search term |
| search_by | string | no | Property to search: "name" (default) or "domain" |
| limit | string | no | Maximum results (default 10, max 50) |

## Response

Returns a formatted list of matching companies:

```
Found 2 companies:

ID: 12345
Name: Acme Corp
Domain: acme.com
Industry: Technology

---

ID: 12346
Name: Acme Solutions
Domain: acmesolutions.com
Industry: Consulting
```

## Examples

```
/hubspot.search_companies --query "Acme"
/hubspot.search_companies --query "example.com" --search_by "domain"
/hubspot.search_companies --query "Tech" --limit "5"
```
