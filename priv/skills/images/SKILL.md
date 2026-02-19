---
domain: images
description: "Image generation skills for creating images with OpenRouter image-capable models."
---

# Images Domain

Skills for generating images from text prompts using OpenRouter image models.
Includes model selection, image count control, and provider-specific generation
options like size and aspect ratio.

## Skill Inventory

| Skill | Type | Purpose |
|-------|------|---------|
| images.list_models | Read | List configured image-generation models and tiers |
| images.generate | Write | Generate one or more images from a text prompt |
