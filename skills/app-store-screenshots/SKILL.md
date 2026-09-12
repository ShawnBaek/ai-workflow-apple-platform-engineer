---
name: app-store-screenshots
description: >-
  Prepare or refresh App Store listing screenshots and app preview videos from
  the intended current app version/build. Resolve capture freshness, choose the
  product story, locales and Apple media slots, derive assets from real captures,
  and verify the delivery set. Use for App Store marketing media; use screenshot
  for general PR evidence and app-store-connect for authorized upload.
---

# App Store Screenshots and Previews

Own the listing's story, current-build provenance and ready-to-review media set.
Use `screenshot` for deterministic capture, privacy and raw media integrity,
`xcodebuild` for build/install/run mechanics, and `app-store-connect` for account
operations. Capture and local preparation do not require an ASC account.

## Resolve the target once

Reuse the app repository, platform, intended release/version, locales, reference
style and selected deliverables from the task. Ask only about material missing
choices. Prepare screenshots, recorded video, or both as requested. A request for
both must not lose its recording deliverable during the generic screenshot handoff.

Resolve “latest” from the user's delivery target: current development candidate,
named release candidate, or released App Store version. If those differ and the
task does not select one, clarify before dependent capture. Do not choose by
filename, modification time, largest build number or whichever app is running.
Do not bump the version, merge another branch or upgrade the minimum OS to create
marketing assets. Record selected Xcode/OS separately from the app version.

## Bind captures to the actual app

Before each destination's capture batch:

1. Freeze the selected source commit plus working-diff identity, relevant build
   configuration, localization/resources and feature state. Inspect effective
   version settings and the built bundle's `CFBundleIdentifier`,
   `CFBundleShortVersionString` and `CFBundleVersion`; labels in a filename are
   insufficient. Use the existing build receipt/artifact hash when available.
2. Build only if a matching verified artifact is unavailable. Install that artifact
   on the exact owned destination, terminate an older running instance as needed,
   and launch the installed app. Confirm its identity from the installed bundle,
   test/runtime metadata or a supported diagnostic. If a mismatch remains,
   correct the install/launch and recapture; renaming files does not repair it.
3. A device/TestFlight binary cannot simply be reused on Simulator. If a Simulator
   variant is needed, build from the same frozen release source with equivalent
   user-visible resources/features; record that variant and its verification.
   Never claim that its binary hash equals the device archive. Resolve a material
   visual/feature difference before treating the capture as release media.
4. Start a fresh output set named by version/build, platform, locale and scenario.
   Keep screenshots and recordings from the same resolved build/state. Reuse old
   assets only when their provenance demonstrably matches the target; unknown or
   stale media needs recapture. UI/resource/localization or relevant feature-state
   changes invalidate affected assets and their derivatives.

App Store version metadata and its associated build are separate objects. Apple
does not attest which binary produced an uploaded image; this capture record
supplies that missing traceability. Account reads to confirm a store build go
through the existing private ASC guard, only when the selected lane needs them.

## Choose the story and Apple slots

Read current Apple [screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/),
[preview specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/app-preview-specifications/)
and [upload guidance](https://developer.apple.com/help/app-store-connect/manage-app-information/upload-app-previews-and-screenshots/).
Record the checked date and selected platform/display slots, dimensions, format,
count and locale. A CLI's built-in size table is a secondary check; do not mistake
its default slots for Apple's current requirements or force previews to screenshot dimensions.

Lead with the core benefit in real app use, then the selected features. Reuse an
approved visual direction; for missing marketing direction, ask only about the
relevant references, copy or style. Use truthful localized copy and representative
fictional data. Show only implemented behavior in the target release, with required
context for paid, subscription or account-dependent features. See Apple's
[product-page guidance](https://developer.apple.com/app-store/product-page/)
and [review guidelines 2.3](https://developer.apple.com/app-store/review/guidelines/).

## Capture and derive the deliverables

Follow `screenshot` for stable state, destination ownership, privacy and capture.
Use current supported Apple capture tools first. Read
[capture and verification mechanics](references/capture-and-verification.md)
for command discovery, frame extraction and upload handoff.

- **Screenshots:** capture actual app UI at an accepted size. Keep raw images
  unchanged. Optional device framing, background and localized explanatory copy
  belong in separate exports; preserve the UI's geometry and readable content.
  Do not generate, redraw or retouch app UI to imply an unimplemented feature.
- **Video:** capture the target app in use. Keep an untouched raw recording and
  derive a preview meeting Apple's current video/audio requirements. App previews
  allow straightforward explanatory edits; keep sequence and timing truthful.
  They are a different derivative from a PR acceptance recording, whose relevant
  interaction must remain intact. Do not use filmed hands/devices as preview footage.
- **Frames from video:** if requested, extract a sharp, stable frame from the
  verified recording and record its source hash/time. Preview-size footage may be
  too small for a screenshot slot; recapture a native still instead of upscaling
  it and calling it a full-resolution screenshot.
- **Poster:** select a representative frame from the final preview. Recheck its
  timecode after trimming, and make the story understandable with autoplay muted.

Custom composition, frame extraction and checks use Swift with Apple frameworks
(ImageIO/CoreGraphics, AVFoundation and CryptoKit). Reuse existing helpers and
project capture support; do not add Python, an XCUITest framework or a second
media runtime merely to produce a listing set.

## Verify, present and deliver

Decode each final image and check accepted dimensions, format and absence of an
alpha channel/transparency under the current screenshot requirements.
Play the complete final video and inspect actual orientation, codec, frame rate,
duration, audio and poster frame against the selected current preview spec.
Metadata checks alone do not prove correct UI, audio rights or a truthful story.
Review locale/order, text legibility, crop/safe areas, privacy and build identity.
Compare derivatives against the raw captures before approving the set.

Keep a compact capture record: target app/version/build and source/variant,
destination/OS/locale/scenario, capture time, raw and final hashes, dimensions,
video duration and edit/frame times. Reuse the task's evidence record; no database
or new runtime schema is required. Separate captured, locally verified, reviewed,
uploaded and processed outcomes.

Present the ordered images/contact sheet and playable preview with their build
identity and any omissions. Upload only when authorized for the exact app/version,
localization, slot, order and replacement scope. `app-store-connect` owns that
mutation and must read back stored assets and preview/poster processing. Capture
does not authorize replacement, submission or release.
