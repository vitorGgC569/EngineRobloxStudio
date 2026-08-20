# Optional OpenAI visual-review provider

Status: `STATICALLY_VALIDATED` with an injected transport. No OpenAI request has
been made from this repository, so the real provider remains `NOT_VALIDATED`
until an authenticated capture review completes and its receipt is inspected.

`rqe.openai_vision.OpenAIResponsesVisionProvider` implements the provider-neutral
`VisionProvider` boundary in `rqe.visual_review`. It sends integrity-checked PNG
bytes to `POST /v1/responses` as `input_image` data URLs and asks for a strict
JSON Schema result through `text.format`. This follows the official OpenAI
[image-input guide](https://developers.openai.com/api/docs/guides/images-vision)
and [Structured Outputs guide](https://developers.openai.com/api/docs/guides/structured-outputs).

The adapter has no OpenAI SDK dependency. Its production transport uses
`urllib.request`; tests inject a fake transport and never reach the network.

## Command

```powershell
$env:OPENAI_API_KEY = "..."
python rqe.py visual review artifacts/<runId>/captures/manifest.json `
  --spec contracts/visual/<visual-spec>.json `
  --model <explicit-vision-capable-model-id> `
  --output artifacts/<runId>/visual/review-openai.json
```

There is deliberately no default model. The selected model must support image
input and Structured Outputs, and changing it changes the review's model hash.
The only credential name read is `OPENAI_API_KEY`; there is no CLI key argument.

`--rubric` may point to a separate `rubricByViewpoint` JSON file, but it is only
accepted when it exactly matches the rubric derived from the hash-bound visual
spec. `--prompt-file` is optional and becomes part of the review prompt hash.

The output path is mandatory, must end in `.json`, cannot be named `latest`, and
must not already exist. A missing key produces an immutable `BLOCKED` /
`NOT_VALIDATED` attempt receipt. It never produces a visual score.

## Fail-closed boundaries

The adapter refuses to return evidence when any of these conditions occurs:

- a PNG's bytes no longer match its capture hash;
- `OPENAI_API_KEY` is absent;
- HTTP or transport fails;
- the response, or any message within it, is incomplete;
- the model returns a refusal;
- `output_text` is missing, malformed, duplicated-key JSON, or violates the
  requested schema;
- the provider response omits a viewpoint, rubric criterion, or valid shot
  citation when the engine performs its second validation pass.

The API key exists only in the HTTP `Authorization` header. The request payload,
review artifact, failure receipt, and exception messages never contain it.

## Authority

The command produces a visual-review artifact and explicitly sets
`authorizesRelease: false`. The immutable release run must separately bind the
capture manifest and review, recompute the score, and apply the release policy.
A provider response alone cannot release a build, and model-authored severity
is advisory until independently corroborated by deterministic evidence.

