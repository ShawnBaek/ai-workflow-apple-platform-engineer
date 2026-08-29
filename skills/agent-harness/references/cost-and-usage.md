# Cost-aware routing and completion usage

Use the model the user explicitly selects when it is available. Otherwise choose
only from models available in the current runtime, based on task risk: use an
efficient model for mechanical, bounded work; a balanced model for ordinary
implementation; and a deep model for planning, architecture, ambiguous or
high-risk work, and final review. Current examples—not permanent mappings—are
Codex Luna (efficient), Terra (balanced), Sol (flagship/deep), and Claude
Haiku, Sonnet, Opus. Escalate only for recorded evidence (risk, uncertainty,
failure, or review finding). Escalation changes neither the approved writer nor
the authority boundary.

At task completion, emit `templates/completion-report.json` validated against
`contracts/schemas/completion-report.schema.json`. Include PR links, checks,
screenshot evidence, and only a trimmed video acceptance window; state omitted
checks and residual risk. Evidence paths/URLs are references, not proof unless
their observed result and digest are recorded where available.

Usage is provider/client-reported only. Never infer tokens from text and never
present an estimate as authoritative billing. Record each original report once
under `usage.source_records` using a stable provider/client source ID as the
key; agents, sessions, and models cite those keys. `cached_input_tokens` is a
subset of input and `reasoning_tokens` a subset of output: do not add either
again to totals. Set `usage.status` to `full`, `partial`, or `not_exposed`, and
name unavailable sources. A multi-provider total is informational, not a bill.
Cost must be labelled `provider_reported`, `client_estimate`, or `not_exposed`.

Consult the current official provider material before relying on fields or
prices: [OpenAI model guide](https://developers.openai.com/api/docs/guides/latest-model),
[OpenAI Responses reference](https://developers.openai.com/api/reference/resources/responses),
[Claude model configuration](https://code.claude.com/docs/en/model-config),
[Claude costs](https://code.claude.com/docs/en/costs), and
[Claude Agent SDK cost tracking](https://code.claude.com/docs/en/agent-sdk/cost-tracking).
