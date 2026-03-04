---
name: "web.search"
description: "Search the public web and return a cited answer."
handler: "Assistant.Skills.Web.Search"
tags:
  - web
  - search
  - citations
parameters:
  - name: "query"
    type: "string"
    required: true
    description: "The web search query"
  - name: "provider"
    type: "string"
    required: false
    description: "Optional provider override: openrouter or openai"
  - name: "limit"
    type: "integer"
    required: false
    description: "Maximum citations/results to request (default 5, max 10)"
  - name: "model"
    type: "string"
    required: false
    description: "Optional model override"
  - name: "search_context_size"
    type: "string"
    required: false
    description: "Provider hint for search context size"
  - name: "engine"
    type: "string"
    required: false
    description: "OpenRouter engine hint, such as native"
---

# web.search

Search the public web and return an answer with preserved citations.

Use `--provider openrouter` or `--provider openai` to force a provider. By
default, the assistant prefers OpenRouter and falls back to OpenAI API-key
search when available.
