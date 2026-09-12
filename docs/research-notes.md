# Workflow sources and decisions

Reviewed 2026-09-05. These are design inputs, not performance benchmarks for this
repository. Provider implementations and model choices remain runtime-specific.

| Source | Useful principle | Application here |
| --- | --- | --- |
| [OpenAI: harness engineering](https://openai.com/index/harness-engineering/) | Repository knowledge and executable checks make agent work inspectable | Small skill entry points, exact source/evidence identity, Swift contract checks |
| [Anthropic: effective harnesses for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) | Explicit progress and bounded work support continuation | Clear intake, scoped work, durable state, targeted verification |
| [Anthropic: harness design for long-running apps](https://www.anthropic.com/engineering/harness-design-long-running-apps) | Evaluate the workflow around the model | Independent review and evidence-linked correction, without automatic merge |
| [Anthropic: agent evaluations](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents) | Check outcomes and meaningful failure modes | Behavior fixtures and real process contention; avoid prose-phrase tests |
| [Google: ADK Go 2.0](https://developers.googleblog.com/announcing-adk-go-20/) | Explicit workflow boundaries can support orchestration | Bounded tasks and selective dependencies; no additional agent framework dependency |
| [Microsoft Research: GraphRAG](https://www.microsoft.com/en-us/research/blog/graphrag-improving-global-search-via-dynamic-community-selection/) | Graph retrieval addresses particular relationship/global-query needs | Keep local FTS retrieval optional; do not add a graph database for ordinary source lookup |

The [graph decision](adr/0001-use-graphs-for-real-dependencies.md) limits complexity.
An ADR is warranted by a significant decision, not every assignment. Reuse
[task intake](../skills/agent-harness/references/task-intake.md) and the existing
architecture before adding layers or orchestration.

Apple guidance remains authoritative for platform behavior. The added AI skills
separate [Foundation Models](../skills/apple-foundation-models/SKILL.md),
[AI evaluation](../skills/apple-ai-evaluation/SKILL.md),
[custom model integration](../skills/apple-model-integration/SKILL.md), and
[App Intents](../skills/app-intents/SKILL.md). Their references include the relevant
WWDC26 sessions and API pages. Foundation Models began in 2025; new 2026 APIs are
not all available on its original minimum OS. Verify the selected SDK interface,
per-symbol availability/back deployment, release status, and runtime readiness.

## Spotify, Shopify, Uber, Netflix and Apple comparison

Checked first-party engineering posts and Apple WWDC material on 2026-09-05.
The application column is our interpretation for this collection. Their reported
scale and percentages are not benchmarks, targets or proof for our implementation.

| Source and date | Supported observation | Comparison and decision here |
|---|---|---|
| [Spotify: Honk feedback loops](https://engineering.atspotify.com/2025/12/feedback-loops-background-coding-agents-part-3), 2025-12-09 | Deterministic verifiers return focused feedback; a separate check compares the diff with the request. CI can pass even when behavior is wrong. The post explicitly says its judge had not yet received structured evals. | Keep local checks plus independent review. Make weakened assertions, disabled checks and unrelated edits visible in review; do not assume an LLM judge is reliable simply because it vetoes changes. |
| [Shopify: production-ready agentic systems](https://shopify.engineering/building-production-ready-agentic-systems), 2025-08-26 | Evaluation cases come from observed interactions, and model judges are compared with human judgments. | Extend the workflow plan from sanitized reported failures, separating tuning examples from held-out cases. Start with a few reviewed cases; no mandatory multi-judge service or statistical machinery for a small skill edit. |
| [Shopify: a harness that outlasts the model](https://shopify.engineering/building-an-agentic-harness-that-outlasts-the-model), 2026-07-29 | Focused discovery runs in parallel, while verification is serialized to avoid shared test-resource collisions. Candidate findings need evidence from the applicable execution path. | Our single writer, resource admission and independent review already fit. Preserve these boundaries; do not copy its scanner fleet or require a different model for every ordinary review. |
| [Shopify: mobile E2E stability](https://shopify.engineering/mobile-e2e-testing), 2026-08-12 | Fixed sleeps and checking hierarchy presence caused misleading failures/passes. Their replacement asserts action outcomes and provides a diagnostic recording. | Strengthen outcome/state checks and focused failure evidence using existing Swift/XCTest support. Keep stable accessibility identifiers; their Appium/OCR wrapper is not a reason to replace native selectors or add a new UI framework. |
| [Uber: efficient software factory](https://www.uber.com/us/en/blog/efficient-software-factory/), 2026-08-27 | Real-work benchmarks compare quality, latency and outcome cost across models. The post holds a model constant for some cost comparisons and describes context lookup as a significant source of work. | Compare model/effort choices on the same bounded tasks and count failed attempts and rework. Reuse relevant source pointers and bounded output. Keep our graph decision: Uber's cross-system graph scale does not establish a need for one here. |
| [Netflix: the data canary](https://netflixtechblog.com/the-data-canary-how-netflix-validates-catalog-metadata-18b699d58e36), 2026-02-06 | Checking inputs missed corruption in the final consumed output. Controlled bad data demonstrated that the validator could detect a failure and block publication. | Add a known-bad control when evaluating a changed verifier and check the final artifact/outcome. Use isolated fixtures here; no production chaos testing or continuous canary infrastructure. |
| [Apple: robust evaluations for agentic apps](https://developer.apple.com/videos/play/wwdc2026/299/), WWDC26 | Evaluate both outputs and tool behavior, including relevant arguments and ordering constraints. | Clarify trajectory checks in `apple-ai-evaluation` and the workflow plan. Accept equivalent valid routes; enforce order only where permissions or behavior depend on it. Use Evaluations only on a compatible SDK/evaluation destination. |
| [Apple: debugging/profiling agentic experiences](https://developer.apple.com/videos/play/wwdc2026/243/), WWDC26 | Instruments exposes model/session behavior and latency so diagnosis can follow the actual flow. | Keep model-quality evidence separate from measured runtime performance. Existing performance and AI skills own these tasks; Simulator screenshots cannot establish device inference speed. |

[Shopify's gisting post](https://shopify.engineering/gisting) (2026-08-19) describes
trained special-token embeddings, not ordinary text summarization. We retain
progressive skill loading and concise source-linked results; learned compression
and model-serving changes are outside this collection's current needs.

The concrete additions are in the [workflow test plan](workflow-test-plan.md),
[review guidance](../skills/code-review/SKILL.md),
[UI testing reference](../skills/apple-platform-testing/references/xctest-and-ui-automation.md),
[model cost policy](../skills/agent-harness/references/cost-and-usage.md), and
[AI evaluation skill](../skills/apple-ai-evaluation/SKILL.md). These are guidance
improvements. The plan continues to label live integration and performance gaps;
reading the sources does not turn those unexecuted scenarios into passes.
