---
name: "hubspot.search_contacts"
description: "Search for contacts in HubSpot CRM by email or name."
handler: "Assistant.Skills.HubSpot.Contacts.Search"
tags:
  - hubspot
  - crm
  - contacts
  - read
  - search
parameters:
  - name: "query"
    type: "string"
    required: false
    description: "Search term (email address or name). Required unless using --filters."
  - name: "search_by"
    type: "string"
    required: false
    description: "Field to search: 'email' (exact match, default) or 'name' (partial match)"
  - name: "limit"
    type: "string"
    required: false
    description: "Maximum results to return (default 10, max 50)"
  - name: "filters"
    type: "string"
    required: false
    description: "JSON array of filter objects for advanced multi-filter search (AND logic). Each object needs 'property', 'operator', and 'value' keys."
---

# hubspot.search_contacts

Search for contacts in HubSpot CRM. By default searches by exact email match.
Use `--search_by name` for partial name matching.

For advanced searches with multiple criteria, use the `--filters` parameter.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| query | string | no* | Search term. *Required unless using --filters. |
| search_by | string | no | Field to search: "email" (default) or "name" |
| limit | string | no | Maximum results (default 10, max 50) |
| filters | string | no | JSON array of filter objects for multi-filter search |

## Response

Returns matching contacts:

```
Found 2 contacts:

ID: 123
Email: jane@example.com
First Name: Jane
Last Name: Doe

---

ID: 456
Email: jane@other.com
First Name: Jane
Last Name: Smith
```

## Example

```
/hubspot.search_contacts --query "jane@example.com"
/hubspot.search_contacts --query "Jane" --search_by name --limit 5
/hubspot.search_contacts --filters '[{"property":"company","operator":"EQ","value":"Acme"},{"property":"firstname","operator":"CONTAINS_TOKEN","value":"Jane"}]'
```

## Usage Notes

- Email search uses exact match (`EQ` operator).
- Name search uses partial match (`CONTAINS_TOKEN` operator) on first name.
- Results are capped at 50 regardless of the limit value.
- The `--filters` parameter supports AND logic — all filters must match.
- When using `--filters`, the `--query` and `--search_by` parameters are ignored.
