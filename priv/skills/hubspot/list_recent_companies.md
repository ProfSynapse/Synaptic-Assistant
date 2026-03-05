---
name: "hubspot.list_recent_companies"
description: "List recently created or updated companies in HubSpot CRM."
handler: "Assistant.Skills.HubSpot.Companies.ListRecent"
tags:
  - hubspot
  - crm
  - companies
  - read
  - list
parameters:
  - name: "limit"
    type: "string"
    required: false
    description: "Maximum number of results (default 10, max 50)"
  - name: "after"
    type: "string"
    required: false
    description: "Pagination cursor from a previous response to fetch the next page"
---

# hubspot.list_recent_companies

List the most recently created or updated companies in HubSpot CRM.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| limit | string | no | Maximum results (default 10, max 50) |
| after | string | no | Pagination cursor from a previous response |

## Response

Returns a formatted list of companies:

```
Found 3 companies:

ID: 12345
Name: Acme Corp
Domain: acme.com
Industry: Technology

---

ID: 12346
Name: Globex Inc
Domain: globex.com
Industry: Manufacturing

---

ID: 12347
Name: Initech
Domain: initech.com
Industry: Software

More results available. Use --after abc123 to see the next page.
```

## Example

```
/hubspot.list_recent_companies
/hubspot.list_recent_companies --limit "5"
/hubspot.list_recent_companies --after "abc123"
```
