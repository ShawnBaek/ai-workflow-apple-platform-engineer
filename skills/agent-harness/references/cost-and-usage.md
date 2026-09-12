# Cost-aware routing and completion usage

## Select capability for the actual work

Preserve an explicit user-selected model within its stated scope. Otherwise
resolve available model IDs and supported effort settings at dispatch time:

| Work | Initial class / effort | Execution |
| --- | --- | --- |
| Narrow lookup, formatting, bounded mechanical edits, fixture preparation | simple / low | Direct tools for tiny work; a lightweight worker for a useful independent batch |
| Ordinary SwiftUI/UIKit implementation, scoped bug fix, focused test, normal review | standard / medium | One writer and, where required, one independent reviewer |
| Actor reentrancy, data-loss risk, ambiguous crash, cross-layer performance diagnosis | deep / high | Stronger reasoning for this bounded risk; supporting work stays economical |
| Unresolved unusually difficult reasoning | strongest suitable available capability | Escalate with the specific gap and supporting evidence |

Lead, planner, and reviewer are responsibilities, not reasons to use the highest
model. Risk follows behavior, not diff size. Loading a skill cannot change a
model. Bind model **and** effort using the client's supported dispatch or agent
configuration; inspect the effective resolved values. A full-history fork can
inherit an expensive parent and may disallow overrides: use a supported bounded
context handoff when available, otherwise report the actual fallback.

Current family examples are Codex Luna / Terra / Sol and Claude Haiku / Sonnet /
Opus. They are not permanent aliases or a pricing guarantee. Recheck the current
runtime catalog; do not write unsupported global configuration keys. Changing a
model never transfers writer ownership, approval, tools, or account authority.

Start with one agent. Delegate only an independently bounded task while the lead
can make different useful progress. One or two workers is a reasonable initial
cap within the host limit, not a quota. Avoid nested delegation and a new agent
per skill, file, or review lens. Give the exact revision, scope, relevant sources,
allowed actions, deliverable, and stopping condition. Return findings/artifact
pointers; keep full logs outside model context. An implementation worker writes
only under the established writer transfer or into an explicitly isolated
scratch checkout whose changes the writer reviews and integrates.

Agent concurrency is separate from Xcode workers, test clones, booted devices,
and local-model RAM. Admit heavy work through host resource budgets. A cheaper
cloud model does not reduce Simulator memory or build storage. Queue work under
pressure and reuse compatible evidence rather than repeating builds.

Escalate for a supported finding or reasoning gap, then return routine work to
its usual class. Access errors, missing SDKs, and identical retries need their
actual cause fixed. Record provider, resolved model, effort, class, reason,
boundary, outcome, and exposed usage privately. Judge routing by accepted
outcomes, latency, and rework as well as tokens. Do not put this operational
record into every PR description.

For routing comparisons, use the same representative tasks and acceptance
criteria. Report verified outcomes, failed attempts, retries and human rework.
Compare quality, latency and total exposed cost including failures per verified
outcome; the ratio is undefined with no successes. Record changed model/effort,
prompt, tools and cache conditions. Keep unknown usage unknown and avoid changing
defaults from one run. This adapts
[Uber's outcome-based benchmarking](https://www.uber.com/us/en/blog/efficient-software-factory/).

## Completion usage

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
