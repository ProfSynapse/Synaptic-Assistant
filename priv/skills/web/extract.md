---
name: "web.extract"
description: "Extract readable text from a web page, optionally scoped by selector."
handler: "Assistant.Skills.Web.Extract"
tags:
  - web
  - extract
parameters:
  - name: "url"
    type: "string"
    required: true
    description: "The URL to extract from"
  - name: "selector"
    type: "string"
    required: false
    description: "Optional CSS selector for a narrower extraction target"
  - name: "save_to"
    type: "string"
    required: false
    description: "Optional path in the assistant file workspace to save the extracted content"
  - name: "max_chars"
    type: "integer"
    required: false
    description: "Maximum characters to return in the tool result"
---

# web.extract

Extract readable text from a page. This uses the same safety checks as
`web.fetch`, but is intended for content-focused extraction.
