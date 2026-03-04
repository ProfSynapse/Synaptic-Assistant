---
name: "web.fetch"
description: "Fetch a web page, extract readable text, and optionally save it."
handler: "Assistant.Skills.Web.Fetch"
tags:
  - web
  - fetch
  - extract
parameters:
  - name: "url"
    type: "string"
    required: true
    description: "The URL to fetch"
  - name: "selector"
    type: "string"
    required: false
    description: "Optional CSS selector to extract a narrower section"
  - name: "save_to"
    type: "string"
    required: false
    description: "Optional path in the assistant file workspace to save the fetched content"
  - name: "max_chars"
    type: "integer"
    required: false
    description: "Maximum characters to return in the tool result"
---

# web.fetch

Fetch a public web page, extract readable text, and optionally save the result
to the assistant's local file workspace.

The fetch respects URL safety rules and `robots.txt`.
