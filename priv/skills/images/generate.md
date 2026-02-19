---
name: "images.generate"
description: "Generate images with OpenRouter image-capable models."
handler: "Assistant.Skills.Images.Generate"
confirm: true
tags:
  - images
  - generation
  - openrouter
  - write
---

# images.generate

Generate one or more images from a text prompt using an OpenRouter image model.
By default, the model is resolved from `config/config.yaml` via the
`image_generation` use case. You can override the model per request.

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| prompt | string | yes | Natural language image prompt |
| model | string | no | Explicit OpenRouter model ID (for example `openai/gpt-5-image-mini`) |
| n | integer | no | Number of images to generate (1-4, default 1) |
| size | string | no | Provider-specific size, e.g. `1024x1024` |
| aspect_ratio | string | no | Provider-specific aspect ratio, e.g. `16:9` |
| aspect | string | no | Alias for `aspect_ratio` |

## Response

Returns generated image file paths (for data URL responses) and/or remote URLs:

```
Generated 1 image(s) with model: openai/gpt-5-image-mini
Saved files:
- /tmp/generated_images/image_1765000000000_1.png
```

## Example

```
/images.generate --prompt "A cinematic photo of a neon-lit diner on Mars at sunset" --model openai/gpt-5-image-mini --size 1024x1024
```

## Usage Notes

- This is a mutating skill — image generation consumes model credits.
- OpenRouter image generation runs through `/api/v1/chat/completions` with image modalities.
- `size` and `aspect_ratio` support depends on model/provider.
- If no `model` is provided, the assistant uses the `image_generation` default model from config.
- Model options are curated in `config/config.yaml` under `models` with `use_cases: [image_generation]`.
- Use `images.list_models` to see the current configured model IDs and tiers.
