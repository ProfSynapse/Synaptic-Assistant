---
name: "hubspot.list_recent_deals"
description: "List recent deals from HubSpot CRM."
handler: "Assistant.Skills.HubSpot.Deals.ListRecent"
tags:
  - hubspot
  - crm
  - deals
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

# hubspot.list_recent_deals

List recently created or updated deals from HubSpot CRM.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| limit | string | no | Maximum results to return (default 10, max 50) |
| after | string | no | Pagination cursor from a previous response |

## Response

Returns a list of recent deals:

```
Found 3 deals:

ID: 12345
Deal Name: Acme Corp Enterprise License
Amount: 50000
Close Date: 2026-06-30
Stage: appointmentscheduled
Pipeline: default

---

ID: 12346
Deal Name: Globex Consulting
Amount: 25000
Close Date: 2026-05-15
Stage: contractsent
Pipeline: default

---

ID: 12347
Deal Name: Initech Migration
Amount: 80000
Close Date: 2026-08-01
Stage: qualifiedtobuy
Pipeline: default

More results available. Use --after abc123 to see the next page.
```

## Example

```
/hubspot.list_recent_deals --limit 5
/hubspot.list_recent_deals --after "abc123"
```

## Usage Notes

- Returns deals sorted by most recently modified.
- Results are capped at 50 maximum.
- If no deals exist, returns "No deals found."
- When more results are available, the response includes a pagination cursor.
