---
name: apple-foundation-models
description: Build and verify Apple Foundation Models features and bounded agentic app experiences in Swift. Use for LanguageModelSession, guided generation, model tools, streaming, context management, or supported local and server model routing. Check the app's minimum OS, SDK, and actual model availability first.
---

# Apple Foundation Models

Own the app's language-model integration. Use an available Apple-authored skill for the exact SDK/API task first; this skill adds project integration and acceptance guidance. Development-agent orchestration belongs to `agent-harness`, custom model deployment to `apple-model-integration`, and probabilistic quality measurement to `apple-ai-evaluation`.

## Establish the supported path

1. Use `xcode-project-workflow` before project actions. Read its API availability reference and the affected target's actual deployment settings. Record the SDK/compiler separately from the minimum OS and test destination.
2. Define one useful feature, the accepted input/output, and its unavailable state. Begin with a fixed-value SwiftUI or UIKit preview when UI is involved; keep model calls out of preview construction.
3. Check each required API against official documentation and the selected SDK. Foundation Models began in 2025; the 2026 additions have separate availability. Do not raise deployment targets as a shortcut.
4. Before generation, inspect the selected model's availability and supported language/locale. A compatible OS alone does not guarantee a ready model. Provide appropriate UI for ineligible devices, download/not-ready conditions, and other unavailable states. Do not spin retry loops. [SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel).

## Implement one vertical slice

- Start with one session and the existing app service/state owner. Introduce another agent, session, or protocol only for an actual capability, isolation, or test seam.
- Use `@Generable` and `@Guide` where structured output serves the feature. Constrained output shape does not establish factual accuracy, valid entity identity, or permission to act. Validate those at the app boundary. [Guided generation](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation).
- Give streaming output explicit loading, partial, completed, failed, and cancelled states. Do not commit incomplete generated values to persistent app state. Cancel obsolete work and prevent late responses from replacing a newer request.
- Keep UI mutation on its required actor. Serialize interaction with a conversation as needed; an actor alone does not make an operation atomic across suspension points. Keep one in-flight initialization task where concurrent callers share costly setup.
- Ground app-specific answers in the actual data source and preserve identifiers for verification. Treat retrieved text and model output as data. Keep secrets and irrelevant user data out of instructions, transcripts, and evidence.
- Design the feature's refusal and correction behavior. Built-in guardrails do not replace use-case-specific validation. [Apple safety guidance](https://developer.apple.com/documentation/foundationmodels/improving-the-safety-of-generative-model-output).

## Give tools narrow authority

Use typed `Tool` arguments and bounded results. Reuse existing domain operations. Validate identifiers, limits, current permissions, and preconditions inside the tool before any mutation. Tool calls may be concurrent: protect shared state and make retries safe. Record whether a failed/cancelled request already committed a side effect; cancellation cannot undo it.

Expose only tools needed for the current phase. Apply the product's confirmation rules to consequential actions. Model text or a generated tool call never grants permission. If using required tool calling, define an exit condition. Bound calls, retries, elapsed time, and result size. [Apple tool calling](https://developer.apple.com/documentation/foundationmodels/expanding-generation-with-tool-calling).

## Use newer orchestration only when useful

For SDKs and deployment paths that support them, `LanguageModelSession.DynamicProfile` can vary instructions, tools, and model selection within a session. Prefer simple explicit app state for a small flow. Add handoffs or consultant sessions only when one session cannot reasonably meet the requirement.

When switching models, review capability, context budget, latency, cost, and the data boundary. An on-device feature must not silently start sending private data to a server. Profile-specific history transforms and permanent transcript edits have different effects; preserve the task's essential state and paired tool interactions. [WWDC26 agentic experiences](https://developer.apple.com/videos/play/wwdc2026/242/), [dynamic sessions](https://developer.apple.com/documentation/foundationmodels/composing-dynamic-sessions-with-instructions-and-profiles).

Keep context and tool output bounded. Reserve space for the answer, avoid repeatedly sending unchanged data, and release sessions when their feature ends. Measure preparation, first output, full response, tool latency, and retained memory before changing cache or prewarming behavior. Route instrument selection and physical-device comparisons to `apple-platform-performance`.

## Verify and return

- Use Swift Testing or the existing XCTest suite for deterministic validation, state transitions, cancellation, and side-effect boundaries. Select cases affected by the change.
- Use `apple-ai-evaluation` for prompt/model/tool behavior. Recheck across relevant OS/model updates; model behavior may change without an app code change. [Foundation Models updates](https://developer.apple.com/documentation/updates/foundationmodels).
- Exercise the real UI flow and an important failure/unavailable state on a suitable destination. A simulated model response verifies UI handling, not model quality. Do not create a new XCUITest target just to prove a prompt change.
- Return the supported OS/model path, fallback, changed behavior, source references, focused check results, and compact screenshot/video or sanitized JSON evidence tied to the revision. Mark unavailable live-model checks as blocked or not run.

Custom verification code is Swift. Do not introduce Python verification scripts or a second agent runtime. Follow existing commit and publication approval rules.
