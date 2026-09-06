# App Store media workflow checks

Scope: new `app-store-screenshots` and neighboring routes, based on
`a2428e70f3bd908b7dac285ae7c1f1db60757ca6`. The skill adds capture provenance and
listing preparation; it does not ship another media runtime.

## Executed tool probes

Synthetic format fixtures were generated with Swift and Apple frameworks. They
are visibly labeled fixtures, not screenshots or recordings of a real app.

| Probe | Observed result |
|---|---|
| Opaque 1242 × 2688 PNG; `asc screenshots validate --device-type IPHONE_65` | Exit 0, one ready file. |
| Opaque 320 × 480 PNG, same selected slot | Expected exit 1 with `dimension_mismatch`; no ready files. |
| Swift/AVFoundation moving-shape video | Generated 886 × 1920, 30 fps, 16 seconds, one video track. |
| `avconvert` passthrough trim, start 1 second, duration 15 seconds | Exit 0; AVFoundation decoded the result as 15 seconds, 886 × 1920, 30 fps. |
| AVFoundation frame extraction | Requested and returned 7.5 seconds; frame decoded at 886 × 1920, with source and frame hashes recorded. |

Installed CLI: `asc 2.2.0`. Helpers used Swift 6.4; custom generation and inspection
used Apple frameworks, with no Python or additional capture dependency. The
initial helper compilation failed for a missing `-parse-as-library` option; the
corrected compile and raw diagnostic were retained. `avconvert --help` printed its
help and returned 205; this was not treated as a failed conversion. The task-owned
probe folder was approximately 1.9 MB. This is not a performance benchmark.

The positive screenshot and extracted frame were visually inspected for their
fixture labels. Complete real-app playback, audio, source/build identity and App
Store processing were not exercised. These size fixtures are test inputs, not a
recommendation to use a fixed annual display table.

## Proposed-action evaluation

A separate agent received the candidate guidance and four raw fixtures. It
produced these proposed routes without running an app or publishing anything:

One bounded recheck recorded these hashes before reading the final source:

| Loaded path | SHA-256 |
|---|---|
| `skills/app-store-screenshots/SKILL.md` | `99dc91474a5d210a6a2302dc5f13dc0ab3a6aea661b9ff2dbbeb6f0e0ae91c68` |
| `skills/app-store-screenshots/references/capture-and-verification.md` | `da9e27d6614a750151f3b451f96d4a8fe74aa599c1bb22f39ea6159d2a3ac813` |
| `skills/screenshot/SKILL.md` | `3bf0cbd4d31aa0365e263db8c74e1477534b97c85c6d8361463bfbab57f16577` |

Client: Codex; requested model/effort: `gpt-5.6-luna/medium`; effective provider
identity and usage: unknown. Publication mode: none. Only the summarized proposals
below are committed here; the original and final action records remain in the
maintainer's local evaluation artifacts. The final recheck confirmed these routes:

- Settled release `3.4.0 (81)`, older installed app and mixed/unknown `latest/`
  artifacts: install/verify the matching artifact and freshly capture both
  requested screenshots and preview; do not trust file labels or upload.
- Verified 886 × 1920 preview, 1242 × 2688 screenshot slot: arrange native still
  capture of the same build; do not upscale the frame into a claimed native still.
- PR animation evidence only: use `screenshot`, without ASC or listing setup.
- Device IPA for Simulator capture: build a separate same-source Simulator
  variant, verify user-visible parity and record its distinct identity.

All four proposed routes respected the stated scope. No prior agent baseline was
run for this new entry point, and these proposals do not prove live app capture.

## Remaining verification

Repository metadata/link validation passed. An independent review resolved three
follow-ups: explicit preview/poster mutation scope, listing-versus-raw-capture
ownership, and deletion behavior for both screenshot/preview replacement flags.

The reviewer also attempted Swift tests under standalone Command Line Tools;
that attempt failed because XCTest was unavailable. No runtime source/contract
changed and no runtime-suite pass is claimed for this guidance patch. The
existing verifier was reused for document checks. Apple specifications and selected
`asc`/`simctl` help were inspected; Apple remains authoritative over CLI defaults.

Not run: stale installed-app replacement, real release-build capture, localization
or screenshot framing of a real app, device/Simulator parity, complete preview
playback/audio review, ASC upload/poster processing, or installed-client routing.
The next integration needs one selected app/build and authorized destination.
The synthetic fixtures must never be uploaded as App Store listing media.
