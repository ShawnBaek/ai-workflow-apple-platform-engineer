---
name: apple-model-integration
description: Integrate custom machine-learning model artifacts into Apple apps with an appropriate supported runtime, bounded loading and caching, and Swift verification. Use for Core AI or Core ML model deployment and justified MLX integration; route language-model app behavior to apple-foundation-models and profiling to apple-platform-performance.
---

# Apple Model Integration

Own custom model loading and app integration. Reuse an Apple-authored skill when it already owns the exact runtime task. Do not duplicate the performance specialist's profiling instructions or turn a model import into an app architecture rewrite.

## Select the supported runtime

Use `xcode-project-workflow` and its API availability reference. Identify the app's minimum OS, target platforms, selected SDK, hardware requirements, model artifact format, and existing runtime before changing anything.

| Need | Starting point |
| --- | --- |
| Apple-provided language-model behavior | `apple-foundation-models`; a custom runtime may be unnecessary |
| Existing compatible Core ML feature or an older supported deployment path | Preserve Core ML unless a measured requirement justifies migration |
| Custom model deployment on a supported new SDK/OS | Evaluate Core AI using its Swift API and compatible artifact |
| Custom Apple-silicon model experimentation or an established MLX stack | Inspect the pinned MLX/Swift package and supported platforms before choosing it |

Core AI is a new WWDC26 runtime with Swift inference APIs and device specialization. Its availability and model formats are separate from Core ML. MLX is another ecosystem with its own package and hardware constraints. Do not promise that the same artifact or fallback works across them. [Meet Core AI](https://developer.apple.com/videos/play/wwdc2026/324/), [Core ML](https://developer.apple.com/documentation/coreml), [Apple MLX Swift](https://github.com/ml-explore/mlx-swift).

## Integrate without unnecessary layers

1. Record the artifact's source, version/hash, expected inputs/outputs, shape/dtype, preprocessing, tokenizer where applicable, and licensing/redistribution constraints. Reuse approved artifacts; do not download a large model speculatively.
2. Implement the smallest loader and inference boundary in the existing feature. Preserve training-time preprocessing and output interpretation. Treat malformed outputs and incompatible shapes as explicit errors.
3. Share expensive initialization through an in-flight task when appropriate. Define cancellation, retry, failure recovery, and lifetime. An actor can reenter across `await`; it does not by itself prevent duplicate loads.
4. Bound input size, batch size, concurrent inference, and retained state. Keep heavy setup off the interactive path. Start with high-level APIs; use custom kernels, preallocated tensors, or zero-copy paths only after measurement identifies their benefit.
5. Handle missing/downloaded/corrupt assets, insufficient resources, and unavailable capabilities with a useful UI state. Do not silently switch to a server or a materially different model without an accepted product behavior.

## Manage the model's real costs

Distinguish portable model files, build-time compiled assets, device/OS-specific specialization, and live tensor/session memory. Cache identity must include the inputs that affect compatibility; never reuse arbitrary derived assets across incompatible devices or OS versions.

With Core AI, use its model cache and supported specialization policies. Plan for cache eviction and cold loading. Ahead-of-time compilation reduces remaining device work; it does not eliminate device specialization. Prefer defaults until measurements justify another compute or persistence policy. [Specialization and caching](https://developer.apple.com/documentation/coreai/managing-model-specialization-and-caching), [ahead-of-time compilation](https://developer.apple.com/documentation/coreai/compiling-core-ai-models-ahead-of-time).

Set a feature-appropriate download/cache budget and release unused model state. Do not delete shared Xcode caches or unrelated assets as part of app inference management. Development-machine storage belongs to `xcode-storage`. Check current release notes for background execution restrictions and SDK defects before diagnosing app logic; changing entitlements still follows the user's signing approval policy.

## Verify in Swift

- Check representative and boundary inputs against approved reference outputs using appropriate numerical tolerances and output semantics. Do not demand byte-identical stochastic or cross-hardware results.
- Test the affected loader failure/retry or cancellation behavior at the cheapest meaningful layer. Avoid duplicating the same assertion in UI tests.
- Measure cold setup separately from warm inference. Compare latency, peak/retained memory, and model quality on representative physical hardware, with equivalent inputs and conditions. Route instruments and result interpretation to `apple-platform-performance`.
- Record model hash, preprocessing revision, runtime/SDK/OS, device, options, result samples, and limitations. A Simulator smoke test proves integration only to the extent the actual runtime is supported there.

Custom app verification and result processing use Swift. Apple's model-authoring/conversion ecosystem may require Python; do not call it a Swift-only conversion pipeline. For this workflow, consume a compatible preconverted artifact and trusted reference outputs. If neither exists, report that dependency rather than inventing a converter or silently installing Python tooling.
