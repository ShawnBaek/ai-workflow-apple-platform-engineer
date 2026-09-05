---
name: apple-ai-evaluation
description: Evaluate probabilistic Apple app features with small, representative datasets and Swift-based checks. Use when changing prompts, models, retrieval, guided output, or agent tool behavior; use Apple's Evaluations framework when the selected SDK and evaluation destination support it.
---

# Apple AI Evaluation

Own the quality evidence for model-driven app behavior. Use an available Apple-authored evaluation skill for its exact framework task. `apple-platform-testing` owns ordinary test execution; `apple-foundation-models` owns app integration; `agent-harness` owns coding-agent workflow checks.

## Choose the smallest useful evaluation

Write the feature's expected outcome and failure conditions before tuning its prompt. Pick observable criteria: valid source-backed IDs, correct requested action, appropriate refusal, relevant content, or a latency budget. Keep permission and data-integrity requirements as deterministic code constraints, even when overall response quality is probabilistic. Do not copy a WWDC example's success percentage as a universal threshold. [Designing effective evaluations](https://developer.apple.com/documentation/evaluations/designing-effective-evaluations).

Build a small reviewed dataset covering distinct real scenarios. Include representative successes, relevant edge cases, known regressions, and misuse cases where the feature warrants them. Label expected behavior and source facts. Use real user data only within its permission and retention constraints. Expand after the evaluator produces useful signals; thousands of generated variants are not a substitute for representative cases. [Dataset design](https://developer.apple.com/documentation/evaluations/designing-evaluation-datasets).

Keep tuning examples separate from held-out acceptance examples. Do not tune against every failure in the holdout and continue claiming it is independent. Record changes to the dataset and rubric so comparisons remain meaningful.

## Choose the execution layer

1. Follow `xcode-project-workflow` for project actions and resolve API availability. The evaluation host/destination can have a different OS requirement from the shipping app. Keep the newer evaluation framework in the appropriate test/tool target; never raise the app minimum merely to use it.
2. On a compatible SDK/destination, use Apple's `Evaluations` framework and Swift Testing integration. Define the subject, samples, metrics/evaluators, and aggregation; inspect the evaluation report. [Meet Evaluations, WWDC26](https://developer.apple.com/videos/play/wwdc2026/298/), [Evaluation API](https://developer.apple.com/documentation/evaluations/evaluation).
3. If unavailable, use a small Swift test/helper with Codable fixtures and structured results, or report the unsupported live evaluation. Do not recreate Evaluations as a framework, add Python, or invent unsupported APIs.
4. Run model/service evaluations below the UI where possible. Use the real app for interaction and fallback acceptance. Add XCUITest only for a critical interaction that cannot be adequately checked through existing coverage or a focused runtime exercise.

## Grade the right thing

- Prefer deterministic checks for schema, membership in retrieved IDs, numeric bounds, mutation permissions, and tool effects. Inspect required tool arguments and ordering dependencies as well as the final output; a plausible response can hide a missing action. Accept equivalent valid routes instead of requiring one exact sentence or arbitrary tool sequence. [Tool evaluations, WWDC26](https://developer.apple.com/videos/play/wwdc2026/299/).
- Use a model judge only for a quality dimension that code cannot reasonably judge. Supply the rubric and relevant evidence, identify the judge/configuration, and calibrate on human-reviewed examples. A judge's opinion is not ground truth or permission to waive a reproducible defect.
- Report results by meaningful category as well as aggregate. A good average can conceal a broken locale, a privacy boundary, or a consistently failing edge case.
- Retain errors, timeouts, refusals, and unavailable-model results. Separate feature behavior from infrastructure failure. Never turn an unavailable run into a pass or retry until a favorable sample appears.
- For stochastic checks, choose and record a bounded repeat policy before comparing candidates. Show counts and variation; a tiny sample does not establish a production reliability percentage.
- Inspect surprising failures for bad labels, a defective grader, changed retrieval, or a changed model before editing implementation. Keep disputed results visible while investigating.

## Keep cost and evidence bounded

Start with the affected samples and a small stable regression set. Broaden for a new model, changed supported OS, or failures that reveal wider risk. Bound concurrent generations, tool calls, time, and artifact size; do not combine unlimited evaluations with simultaneous Simulator/build jobs.

Use a concrete revision, dataset/rubric hash, prompt version, tool implementation revision, OS/SDK, locale, model/provider identifier when exposed, and generation settings. Record “not exposed” for model identity that the API does not reveal; do not fabricate a pinned on-device model version.

Keep sanitized input/output examples for failures, expected/observed behavior, per-category counts, and the focused command/result bundle. Avoid storing private full transcripts by default. Measure performance with `apple-platform-performance`; Simulator timings cannot establish device inference performance.

Return a short conclusion: what improved or regressed, which criteria passed, uncertainty or blocked coverage, and links to evidence. Follow the existing PR template and approval rules. A screenshot can show the interaction; JSON/evaluation results support the quality claim.
