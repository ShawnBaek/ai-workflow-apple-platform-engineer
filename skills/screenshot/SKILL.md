---
name: screenshot
description: >-
  Captures and verifies deterministic iOS, iPadOS, watchOS, and macOS screenshots or videos for pull-request evidence and App Store listings. Use for visual acceptance evidence, localized screenshots, interaction recordings, framing, or App Store screenshot upload. Uses current Apple specifications and Xcode official capture tools first; publication and upload remain explicit gated actions.
---

# Screenshot and Video Evidence

Own the scenario, deterministic state, capture matrix, privacy review, artifact
integrity, framing, and publication. Route build/run/UI mechanics to `xcodebuild`
and store upload/account operations to `app-store-connect`.

## Plan from the acceptance criterion

Choose only the affected evidence:

- static UI: relevant destination, appearance, and material text-size state;
- iPad layout: relevant window size/size class/orientation;
- watchOS: relevant watch destination and Crown/button interaction when changed;
- macOS: native or Catalyst explicitly, plus relevant window size;
- interaction/motion: a short video or UI-test recording, not many still images;
- localization: only affected locales plus a fallback-language check.

For App Store assets, retrieve the current display types, resolutions, count,
file types, and upload rules from Apple's live screenshot specification. Do not
trust a hardcoded annual device table.

## Deterministic capture

1. Complete the Xcode project/host preflight and acquire the exact destination
   lease.
2. Use launch arguments/environment, a fixture, dependency injection, or an
   approved debug seam to create repeatable state. Do not copy private files
   directly into Simulator containers as a default shortcut.
3. Use stable accessibility identifiers and explicit readiness conditions. Do
   not sleep for a guessed download duration.
4. Use Xcode's official Simulator/device interaction and capture tools first.
5. Name artifacts by platform, OS/destination, locale, sequence, and scenario.
6. Record source commit/diff hash, toolchain, scenario, dimensions/duration, and
   SHA-256.

For first-run downloads, wait on an observable app-ready signal or use an
approved deterministic fixture. A loading screen is evidence only when loading
is the acceptance criterion.

## Verify before publishing

- Decode every image and verify dimensions against the current target slot.
- Inspect the full video, codec/container, duration, and playback.
- Check visual content against the acceptance criterion; file existence is not
  a pass.
- Scan for tokens, accounts, email, location, notifications, user data, and
  personal status-bar information.
- Confirm locale, ordering, appearance, and accessibility state.

## PR evidence

`gh pr create` does not provide a documented arbitrary local-attachment flag.
Use a policy-approved committed image with a full-commit permalink, GitHub's
browser attachment flow, or an Actions artifact with digest and retention/expiry
stated. Verify the final PR preview/link for the intended viewer. Do not use an
undocumented upload endpoint or present an expiring artifact as permanent proof.

## App Store upload

Capture-only is the default. Before upload, verify the current private Apple
account/team guard, app/version, locale, display type, order, and live specs.
Upload only with explicit authority, then list/read back the stored assets. An
upload command succeeding without read-back is not completion.

## Never

- hardcode a device/spec table as current truth;
- capture or upload before resolving the target scenario;
- use arbitrary labels or coordinates when stable identifiers are available;
- fabricate production data or expose real customer/user data;
- auto-upload, submit, or replace live screenshots from a capture request;
- require a third-party capture tool when Xcode official tools can do the job.

References:

- [App Store Connect screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications)
- [Recording UI automation for testing](https://developer.apple.com/documentation/xcuiautomation/recording-ui-automation-for-testing)
- [GitHub file attachments](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/attaching-files)
