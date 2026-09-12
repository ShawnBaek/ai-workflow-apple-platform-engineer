# Part VI — Model and audio performance

Measure the user-visible interval: first useful model response, a warm inference,
or audible playback after an intentional action. Record model version, input,
compute configuration, device, OS, thermal state, and cold/warm state. Simulator
results describe that host environment; use a physical device to assess Neural
Engine execution, energy, and the shipped experience.

## Item 24 — Load once when needed, with explicit lifetime

Use the asynchronous [`MLModel.load(contentsOf:configuration:)`](https://developer.apple.com/documentation/coreml/mlmodel/load(contentsof:configuration:))
for a compiled model asset when supported by the deployment target. Compilation
and loading are separate costs. Do not put either on the launch critical path
unless the initial experience actually requires the model. Measure launch and
first use separately before adding prewarming.

An actor alone does not deduplicate asynchronous loading: another caller can
enter while the first call is suspended. At the existing model-owner seam:

1. Return a cached model when available.
2. Join an existing in-flight load; otherwise store the new task **before** the
   first `await`.
3. Associate the task with a generation/identity. Only that generation may
   publish a result or clear a failed load, so an older completion cannot erase
   a replacement after cancellation or reset.
4. Define cancellation ownership. One cancelled waiter must not cancel a load
   still needed by other consumers. Check waiter cancellation before publishing
   UI results. The model owner may cancel shared work on explicit teardown.
5. Retain one model for its useful lifetime; release it and finite temporary
   tensors/buffers under the app's documented lifetime or memory policy.

Use the SDK's actual isolation and `Sendable` contracts. Do not silence compiler
errors with `@unchecked Sendable`, return a non-Sendable model across actors, or
invent a generated model's prediction API. Exercise concurrent first use and
failure followed by retry when changing this logic. A single focused test with
an injected loader is sufficient; it does not need an XCUITest.

## Item 25 — Let measurements guide compute-unit selection

[`MLComputeUnits.all`](https://developer.apple.com/documentation/coreml/mlcomputeunits/all)
allows available compute units, including the Neural Engine. It does not pin
inference to ANE or specify an ANE → GPU → CPU fallback order. `.cpuOnly` can be
appropriate for a measured compatibility or workload requirement; it is not
universally forbidden in production.

```swift
let configuration = MLModelConfiguration()
configuration.computeUnits = .all
let model = try await MLModel.load(
    contentsOf: compiledModelURL,
    configuration: configuration
)
```

Inspect a third-party wrapper's current implementation/configuration before
claiming its defaults or hardware behavior. Do not fork it just to set an
already-used default. Compare supported configurations using the same real
input and physical device. Use the Core ML instrument and supported model
profiling tools to inspect execution; a signpost measures an interval, not which
compute unit ran it. A symbol-name guess is not hardware attribution.

For Foundation Models or newer Core AI work, route to `apple-foundation-models`,
`apple-ai-evaluation`, or `apple-model-integration`. Check minimum OS, selected
SDK, model readiness, cancellation, session/context size, and task quality as
well as latency. Do not apply Core ML tuning knobs to another framework.

## Item 26 — Keep audio scheduling bounded and owned

Keep `AVAudioEngine` and `AVAudioPlayerNode` on a long-lived owner; a function-local
engine that disappears after `play()` is not a complete playback implementation.
Prepare a compatible first buffer before starting playback when the experience
requires immediate sound. Maintain a small measured queue of subsequent buffers
instead of generating an entire long recording into memory.

At the audio owner's established execution context:

```swift
// engine/player are retained, connected, and configured by the audio owner.
player.scheduleBuffer(firstBuffer, completionHandler: nil)
if !engine.isRunning { try engine.start() }
player.play()
```

Keep file/network I/O, model inference, allocation, and blocking synchronization
out of realtime render callbacks. Measure preparation, scheduling, and time to
audible output separately; no universal 50 ms threshold proves correctness.
Recording a smooth UI does not prove uninterrupted audio. Exercise the relevant
output route on a real device and report underruns or audible gaps explicitly.

## Item 27 — Respect interruption, route, and user intent

For AVAudioSession platforms, handle interruption and route-change notifications.
Remember whether the person intended playback before the interruption. Resume
only when that intent still holds, the system permits resuming, and session/
engine reactivation succeeds. Do not call `play()` after swallowed setup errors
or restart audio the person had paused. Pause when the previous output disappears
where appropriate, so private audio does not unexpectedly play through speakers.

Match the framework's notification API and thread/isolation requirements. Tie
observer lifetime and scheduled buffers to the owner. Route changes, media
services reset, background behavior, and format changes need coverage only when
they affect this app's supported playback flow.

For an audio change, a useful focused device check is playback → interruption →
permitted resume, plus output removal when route handling changed. Record the
observed result and related owner/state logic; add an automated state test only
where it prevents a meaningful regression.

## Sources

- [Apple: improving model performance](https://developer.apple.com/documentation/coreml/improving-your-model-s-performance)
- [Apple: handling audio interruptions](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions)
- [Apple: AVAudioEngine](https://developer.apple.com/documentation/avfaudio/avaudioengine)
- [Apple: recording performance data](https://developer.apple.com/documentation/os/logging/recording-performance-data)
