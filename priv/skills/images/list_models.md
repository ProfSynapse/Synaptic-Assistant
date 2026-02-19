---
name: "images.list_models"
description: "List configured image-generation models and tiers."
handler: "Assistant.Skills.Images.ListModels"
tags:
  - images
  - models
  - read
---

# images.list_models

List image-generation models configured in `config/config.yaml`. This helps
choose a model for `images.generate`.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| tier | string | no | Filter to one tier: `primary`, `balanced`, `fast`, `cheap` |

## Response

Returns matching models with tier and cost metadata:

```
Configured image models:
- openai/gpt-5-image-mini (tier: balanced, cost: medium) — GPT-5 Image Mini — faster, lower-cost image generation
- google/gemini-2.5-flash-image (tier: fast, cost: low) — Gemini 2.5 Flash Image — fast multimodal image generation
```

## Usage Notes

- This reads the assistant's local curated model roster from `config/config.yaml`.
- To change available models, update `config/config.yaml` and reload config.
- Use `images.generate --model <model_id>` to pick one explicitly.
