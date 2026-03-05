---
name: "hubspot.search_deals"
description: "Search for deals in HubSpot CRM."
handler: "Assistant.Skills.HubSpot.Deals.Search"
tags:
  - hubspot
  - crm
  - deals
  - read
  - search
parameters:
  - name: "query"
    type: "string"
    required: false
    description: "Search term. Required unless using --filters."
  - name: "search_by"
    type: "string"
    required: false
    description: "Property to search: 'name' (default) or 'stage'"
  - name: "limit"
    type: "string"
    required: false
    description: "Maximum number of results (default 10, max 50)"
  - name: "filters"
    type: "string"
    required: false
    description: "JSON array of filter objects for advanced multi-filter search (AND logic). Each object needs 'property', 'operator', and 'value' keys."
---

# hubspot.search_deals

Search for deals in HubSpot CRM by name or stage. Returns a formatted
list of matching deals.

For advanced searches with multiple criteria, use the `--filters` parameter.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| query | string | no* | Search term. *Required unless using --filters. |
| search_by | string | no | Property to search: "name" (default) or "stage" |
| limit | string | no | Maximum results to return (default 10, max 50) |
| filters | string | no | JSON array of filter objects for multi-filter search |

## Response

Returns matching deals:

```
Found 2 deals:

ID: 12345
Deal Name: Acme Corp Enterprise License
Amount: 50000
Close Date: 2026-06-30
Stage: appointmentscheduled
Pipeline: default

---

ID: 12346
Deal Name: Acme Corp Support Contract
Amount: 12000
Close Date: 2026-07-15
Stage: qualifiedtobuy
Pipeline: default
```

## Example

```
/hubspot.search_deals --query "Acme" --search_by name --limit 5
/hubspot.search_deals --filters '[{"property":"dealstage","operator":"EQ","value":"closedwon"},{"property":"amount","operator":"GTE","value":"10000"}]'
```

## Usage Notes

- `--search_by name` uses a token-contains match on the deal name (partial match).
- `--search_by stage` uses an exact match on the deal stage identifier.
- Results are capped at 50 maximum.
- The `--filters` parameter supports AND logic — all filters must match.
- When using `--filters`, the `--query` and `--search_by` parameters are ignored.
