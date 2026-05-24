# Part VI — CoreML / ANE Inference & AVAudio Pipeline

Items 24–27. For apps that run on-device ML inference (CoreML, CoreML + FluidAudio, Create ML models) and/or real-time audio (AVAudioEngine, AVAudioPlayerNode). The same hang-vs-hitch framework applies, but the bottlenecks are ML load time, ANE scheduling, and audio buffer fill rather than layout or SwiftUI body cost.

---

## Item 24 — Lazy-load the CoreML model; never block launch on MLModel init.

**Why it matters.** `MLModel(contentsOf:)` compiles the model on first load (or reads a pre-compiled `.mlmodelc` from the package). On cold launch with a large model (e.g. 80 MB Kokoro-82M) this can take 500ms–2s on older hardware — long enough to exceed watchdog limits and trigger a launch-time hang in Xcode Organizer.

**Do:**

```swift
actor TTSEngine {
    private var model: MyModel?

    func synthesize(_ text: String) async throws -> AVAudioPCMBuffer {
        if model == nil {
            // Load on first use, not at init time
            model = try await Task.detached(priority: .userInitiated) {
                try MyModel(configuration: MLModelConfiguration())
            }.value
        }
        return try model!.synthesize(text)
    }
}
```

**Don't:**

```swift
// In AppDelegate.application(_:didFinishLaunchingWithOptions:)
let engine = TTSEngine()   // synchronously inits MLModel — blocks the main thread
```

**Measure:** Instruments → App Launch template. Look for `MLModel` in the call tree during `applicationDidFinishLaunching`. Move anything > 50ms off the critical path.

---

## Item 25 — Pin inference to ANE with `MLComputeUnits.all`; add `os_signpost` to measure actual unit.

**Why it matters.** CoreML picks CPU, GPU, or ANE based on the model and the `MLModelConfiguration`. Without an explicit preference, large transformer-style models sometimes fall back to CPU on simulator builds or when Instruments is attached — giving you misleading benchmark numbers. ANE inference is typically 5–10× faster for supported ops and uses a fraction of the battery.

**Do (when you own the MLModel init):**

```swift
let config = MLModelConfiguration()
config.computeUnits = .all          // ANE preferred, GPU fallback, then CPU

// Instrument the actual inference path. Prefer OSSignposter (modern) over
// the C `os_signpost` macros — it threads through Swift concurrency cleanly.
let signposter = OSSignposter(subsystem: "com.myapp.tts", category: "inference")

func synthesize(_ text: String) async throws -> AVAudioPCMBuffer {
    let state = signposter.beginInterval("synthesize", id: signposter.makeSignpostID(),
                                          "chars=\(text.count)")
    defer { signposter.endInterval("synthesize", state) }
    return try model.synthesize(text)
}
```

**When you DON'T own the MLModel init (using a 3rd-party wrapper):**

Many CoreML wrappers (FluidAudio, llama.cpp Swift bindings, Whisper.swift) build the `MLModel` internally and don't expose an `MLModelConfiguration` parameter. In that case:

1. **Don't fork the wrapper just to inject a config** — `MLModelConfiguration()`'s default is already `computeUnits = .all`, which is what you'd set anyway.
2. **Document the assumption** in a comment where the wrapper is initialized — so the next reader knows the ANE choice is left to CoreML's default heuristic, not deliberately CPU-pinned.
3. **Verify on a real device** with Instruments → Core ML (or Time Profiler looking for `ane_` symbols). If you find inference is falling back to CPU, *then* it's worth filing an upstream issue on the wrapper.

```swift
// Wrapper init — defaults to MLModelConfiguration() which is computeUnits=.all.
// FluidAudio doesn't currently accept an external config; verify ANE selection
// on real devices via Instruments → Core ML.
let manager = KokoroAneManager(variant: .english)
try await manager.initialize()
```

**Don't:**

```swift
config.computeUnits = .cpuOnly  // never in production — defeats the ANE
```

**Measure:** Instruments → Time Profiler. Look for `ane_` symbols vs `cblas_` (CPU) vs `GPUFFT` (GPU). The `os_signpost` interval shows up in the Points of Interest track — compare across devices.

**Note:** Simulator always uses CPU — benchmark ANE on a real device.

---

## Item 26 — Pre-buffer the first audio chunk before calling `AVAudioPlayerNode.play()`.

**Why it matters.** `AVAudioPlayerNode` starts playing immediately when you call `play()`. If the synthesized buffer isn't ready yet, the engine runs dry for the first frames and you hear a click, silence, or a stutter at the very start of every utterance. Users perceive this as "the app is broken."

**Do:**

```swift
// Synthesize the first chunk on a background thread before calling play()
func playText(_ text: String) async throws {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: nil)
    try engine.start()

    // Fill the buffer BEFORE play — eliminates the startup gap
    let buffer = try await synthesize(text)      // async, off main thread
    player.scheduleBuffer(buffer, completionHandler: nil)
    player.play()                                 // buffer is already queued
}
```

**Don't:**

```swift
player.play()                          // starts with an empty queue
let buffer = try await synthesize(text)
player.scheduleBuffer(buffer)          // races with the running engine
```

**Measure:** Add `os_signpost(.begin)` at `play()` and `os_signpost(.end)` at `scheduleBuffer()` to measure the gap. Target < 50ms between the two.

---

## Item 27 — Handle AVAudioSession interruptions AND route changes, or audio breaks after every phone call or AirPods disconnect.

**Why it matters.** Two notifications cover the cases that silently break audio playback:

- **`interruptionNotification`** — fires when a call, Siri, or another audio app takes over your session. If you don't observe it and reactivate, the user's next tap produces silence forever (until force-quit).
- **`routeChangeNotification`** — fires when the output route changes (AirPods disconnect, Bluetooth headphones power off, headphones unplugged). Apple's recommended behavior on `.oldDeviceUnavailable` is to pause playback so audio doesn't suddenly blast through the speaker.

Most apps remember to handle one but not the other. Handle both.

**Do (UIKit / @MainActor singleton — the common indie pattern):**

```swift
@MainActor
final class TTSPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    init() {
        setupAudio()
        let center = NotificationCenter.default
        center.addObserver(self,
                           selector: #selector(handleInterruption(_:)),
                           name: AVAudioSession.interruptionNotification,
                           object: AVAudioSession.sharedInstance())
        center.addObserver(self,
                           selector: #selector(handleRouteChange(_:)),
                           name: AVAudioSession.routeChangeNotification,
                           object: AVAudioSession.sharedInstance())
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            player.pause()
        case .ended:
            let opts = AVAudioSession.InterruptionOptions(
                rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            guard opts.contains(.shouldResume) else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            if !engine.isRunning { try? engine.start() }
            player.play()
        @unknown default: break
        }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        // Pause when the previous output disappears (headphones unplugged,
        // BT device powered off) — otherwise audio blasts through the speaker.
        if reason == .oldDeviceUnavailable {
            player.pause()
        }
    }
}
```

**Don't:**

```swift
// No interruption handling, no route handling.
// Silent failures after a phone call. Loud failures after an AirPods disconnect.
```

**Measure:** On a real device:
1. Start playback → receive a phone call → decline → tap Play again. If silent → interruption handler missing.
2. Plug in headphones → start playback → unplug. If audio continues out the speaker → route change handler missing.

Attach Instruments → Time Profiler during both tests to confirm the engine state transitions.

---

## Triage script for ML / audio symptoms

| Symptom | Likely item | First check |
|---------|-------------|-------------|
| App is slow to launch after install | Item 24 | Instruments → App Launch: look for `MLModel` in did-finish-launching call tree |
| First TTS utterance takes > 1s | Items 24 + 25 | `os_signpost` around `synthesize()` on a real device (not sim) |
| Audio has a click / gap at the very start | Item 26 | Add `os_signpost` around `play()` → `scheduleBuffer` gap |
| Audio works, then goes silent after a call | Item 27 | Observe `AVAudioSession.interruptionNotification` |
| Inference is slower on device than expected | Item 25 | Instruments → Time Profiler: `ane_` vs `cblas_` symbols |

---

## References

- **CoreML Performance** → https://developer.apple.com/documentation/coreml/improving-your-model-s-performance
- **MLModelConfiguration.computeUnits** → https://developer.apple.com/documentation/coreml/mlmodelconfiguration/computeunits-swift.property
- **AVAudioSession interruptions** → https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions
- **AVAudioEngine** → https://developer.apple.com/documentation/avfaudio/avaudioengine
- **os_signpost** → https://developer.apple.com/documentation/os/logging/recording-performance-data
