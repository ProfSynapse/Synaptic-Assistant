# OpenRouter JSON Response Format for Turn Classifier

## Executive Summary

The OpenRouter API supports two modes for enforcing JSON output: `json_object` (basic JSON validation) and `json_schema` (strict schema enforcement). The model `openai/gpt-5-mini` supports both modes via the `response_format` request body parameter. The current `turn_classifier.ex` does not pass `response_format` at all, which is why the model sometimes returns non-JSON or markdown-wrapped JSON. Adding `response_format` with either mode will resolve the parsing failures.

**Recommendation**: Use `json_schema` with strict mode and the response healing plugin for maximum reliability.

## Current Problem

In `turn_classifier.ex:110`, the call:
```elixir
@llm_client.chat_completion(messages, model: model, temperature: 0.0, max_tokens: 100)
```
does not pass `response_format`, so the model treats the request as a free-text completion. Even though the prompt says "Reply with JSON only", the model may:
- Wrap JSON in markdown code fences (```json ... ```)
- Add explanatory text before/after the JSON
- Return malformed JSON

The existing `parse_classification/1` strips markdown fences, but this is fragile.

## OpenRouter API: response_format Parameter

### Option 1: json_object Mode (Simple)

Forces the model to return valid JSON, but does not enforce a specific schema.

**Request body addition:**
```json
{
  "response_format": {
    "type": "json_object"
  }
}
```

**Elixir map equivalent:**
```elixir
%{type: "json_object"}
```

**Requirements:**
- The system or user prompt SHOULD instruct the model to produce JSON (OpenAI docs recommend this)
- The model must support `response_format` parameter (gpt-5-mini does)

**Pros:** Simple, lightweight, no schema definition needed
**Cons:** Model could return valid JSON that doesn't match the expected shape

### Option 2: json_schema Mode (Strict) -- RECOMMENDED

Forces the model to return JSON matching an exact schema definition.

**Request body addition:**
```json
{
  "response_format": {
    "type": "json_schema",
    "json_schema": {
      "name": "turn_classification",
      "strict": true,
      "schema": {
        "type": "object",
        "properties": {
          "action": {
            "type": "string",
            "enum": ["save_facts", "compact", "nothing"],
            "description": "Classification action for this conversation turn"
          },
          "reason": {
            "type": "string",
            "description": "One-line explanation for the classification"
          }
        },
        "required": ["action", "reason"],
        "additionalProperties": false
      }
    }
  }
}
```

**Elixir map equivalent:**
```elixir
%{
  type: "json_schema",
  json_schema: %{
    name: "turn_classification",
    strict: true,
    schema: %{
      type: "object",
      properties: %{
        action: %{
          type: "string",
          enum: ["save_facts", "compact", "nothing"],
          description: "Classification action for this conversation turn"
        },
        reason: %{
          type: "string",
          description: "One-line explanation for the classification"
        }
      },
      required: ["action", "reason"],
      additionalProperties: false
    }
  }
}
```

**Pros:**
- Guarantees output matches exact schema at the transformer level
- `enum` constraint prevents invalid action values
- `additionalProperties: false` prevents hallucinated fields
- `strict: true` enforces schema compliance

**Cons:** Slightly more verbose request body

### Response Healing Plugin (Optional Enhancement)

For additional safety, OpenRouter offers a response healing plugin that auto-repairs malformed JSON. Activated by adding to the request:

```json
{
  "plugins": [
    { "id": "response-healing" }
  ]
}
```

**Caveats:**
- Only works for non-streaming requests (turn classifier uses non-streaming, so this is fine)
- Cannot repair truncated responses (ensure `max_tokens` is sufficient)

## Model Confirmation: openai/gpt-5-mini

Verified on OpenRouter's model page:
- `structured_outputs: true`
- `response_format` listed in supported parameters
- 400K context window, mandatory reasoning mode
- Both `json_object` and `json_schema` modes supported

## Integration Point: openrouter.ex

### Current build_request_body (lines 298-313)

The `build_request_body/2` function builds the request map from `messages` and `opts`. It currently handles: `tools`, `tool_choice`, `temperature`, `max_tokens`, `parallel_tool_calls`. It does NOT handle `response_format`.

### Required Change: Add response_format threading

Add a `maybe_add_response_format/2` function in `openrouter.ex` that reads `:response_format` from opts and adds it to the body map. Pattern follows existing `maybe_add_temperature/2`:

```elixir
# In build_request_body/2 pipeline:
body =
  %{model: model, messages: messages}
  |> maybe_add_tools(opts)
  |> maybe_add_tool_choice(opts)
  |> maybe_add_temperature(opts)
  |> maybe_add_max_tokens(opts)
  |> maybe_add_parallel_tool_calls(opts)
  |> maybe_add_response_format(opts)    # <-- NEW

# New function:
defp maybe_add_response_format(body, opts) do
  case Keyword.get(opts, :response_format) do
    nil -> body
    format -> Map.put(body, :response_format, format)
  end
end
```

### Required Change: Turn classifier call site (turn_classifier.ex:110)

Add `response_format` to the opts:

```elixir
response_format = %{
  type: "json_schema",
  json_schema: %{
    name: "turn_classification",
    strict: true,
    schema: %{
      type: "object",
      properties: %{
        action: %{
          type: "string",
          enum: ["save_facts", "compact", "nothing"],
          description: "Classification action for this conversation turn"
        },
        reason: %{
          type: "string",
          description: "One-line explanation for the classification"
        }
      },
      required: ["action", "reason"],
      additionalProperties: false
    }
  }
}

@llm_client.chat_completion(messages,
  model: model,
  temperature: 0.0,
  max_tokens: 100,
  response_format: response_format
)
```

### Optional: Simplify parse_classification/1

With `json_schema` strict mode, the markdown fence stripping in `parse_classification/1` becomes unnecessary since the response is guaranteed valid JSON matching the schema. However, keeping it as defensive code is harmless.

## Summary of Changes Required

| File | Change | Lines Affected |
|------|--------|----------------|
| `openrouter.ex` | Add `maybe_add_response_format/2` + pipe in `build_request_body` | ~298-313 (add pipe), new function |
| `turn_classifier.ex` | Add `response_format` opt to `chat_completion` call | ~104-110 |

## Sources

- [OpenRouter Structured Outputs Docs](https://openrouter.ai/docs/guides/features/structured-outputs)
- [OpenRouter API Parameters](https://openrouter.ai/docs/api/reference/parameters)
- [OpenRouter Response Healing Plugin](https://openrouter.ai/docs/guides/features/plugins/response-healing)
- [OpenRouter openai/gpt-5-mini Model Page](https://openrouter.ai/openai/gpt-5-mini)
- [OpenAI Structured Outputs Guide](https://platform.openai.com/docs/guides/structured-outputs)
- [GPT-5 JSON Consistency Tips (Community)](https://community.openai.com/t/tips-for-improving-gpt-5-json-output-consistency/1360808)
