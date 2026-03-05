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
---

# hubspot.list_recent_companies

List the most recently created or updated companies in HubSpot CRM.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| limit | string | no | Maximum results (default 10, max 50) |

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
```

## Example

```
/hubspot.list_recent_companies
/hubspot.list_recent_companies --limit "5"
```
