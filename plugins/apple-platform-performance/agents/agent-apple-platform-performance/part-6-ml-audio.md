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

**Do:**

```swift
let config = MLModelConfiguration()
config.computeUnits = .all          // ANE preferred, GPU fallback, then CPU

// Instrument the actual inference path
let log = OSLog(subsystem: "com.myapp.tts", category: .pointsOfInterest)

func synthesize(_ text: String) async throws -> AVAudioPCMBuffer {
    os_signpost(.begin, log: log, name: "CoreML inference")
    defer { os_signpost(.end, log: log, name: "CoreML inference") }
    return try model.synthesize(text)
}
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

## Item 27 — Handle AVAudioSession interruptions or the app goes silent after every phone call.

**Why it matters.** iOS deactivates your AVAudioSession when a call, Siri, or another audio app takes over. If you don't observe `AVAudioSession.interruptionNotification` and restart the engine + player after the interruption ends, the user's next tap produces silence — forever, until they force-quit the app.

**Do:**

```swift
final class TTSPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var cancellable: AnyCancellable?

    init() {
        setupAudio()
        cancellable = NotificationCenter.default
            .publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] note in self?.handleInterruption(note) }
    }

    private func handleInterruption(_ note: Notification) {
        guard let type = note.interruptionType else { return }
        switch type {
        case .began:
            player.pause()
        case .ended:
            guard note.interruptionShouldResume else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            try? engine.start()
            player.play()
        default: break
        }
    }
}

private extension Notification {
    var interruptionType: AVAudioSession.InterruptionType? {
        (userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
            .flatMap(AVAudioSession.InterruptionType.init)
    }
    var interruptionShouldResume: Bool {
        (userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
            .map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) }
            ?? false
    }
}
```

**Don't:**

```swift
// No interruption handling — silent after a phone call, no crash, no log
```

**Measure:** On a real device, start playback, receive a call, decline it, then tap Play again. If audio is silent: interruption handling is missing. Attach Instruments → Time Profiler during the test to confirm the engine state.

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
