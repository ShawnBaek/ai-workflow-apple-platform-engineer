---
name: xcode-preview-design
description: >-
  Designs SwiftUI, UIKit, or AppKit interfaces in code with Xcode Previews, deterministic value or protocol fixtures, human-review screenshots, purposeful interaction motion, selective Disney animation principles, and Reduce Motion validation. Use when the developer wants to design without a Figma dependency, review rendered UI before full runtime work, or specify and verify an interaction animation.
---

# Xcode Preview Design

Use the exact opened Xcode project or workspace as the design surface. Figma is
optional, not a prerequisite: when an exact Figma frame is authoritative, route
through `figma-bridge`; otherwise design directly in code. When production view
code must be created or changed, route that bounded implementation node to
`apple-platform-ui`, then resume this Preview review loop.

This skill owns the preview state contract, side-effect-free fixtures, review
loop, and motion specification. It does not replace `xcode-project-workflow`,
`xcodebuild`, `apple-platform-testing`, `screenshot`, or Apple-authored Xcode
capabilities.

## Authority and preflight

1. Complete `xcode-project-workflow`; the exact opened project/container,
   selected Xcode toolchain, deployment targets, and repository conventions are
   authoritative.
2. Prefer the official preview canvas and Xcode-integrated tools already exposed
   by that Xcode window. Do not load a duplicate third-party preview provider.
3. Read Apple's current preview and motion guidance in
   [the review contract](references/preview-and-motion-contract.md) before a
   non-obvious API, motion, accessibility, or compatibility decision.
4. Never change the deployment target, project format, or production
   architecture merely to enable a preview. Use the preview form supported by
   the selected compiler and project.

## Code-first preview loop

1. Freeze one reviewer question and the observable states it needs. Use a
   minimum-sufficient preview matrix, not every theoretical combination.
2. If production view code must change, give the bounded view-layer draft to
   `apple-platform-ui`, then resume here with the resulting implementation.
3. Separate rendering from side effects. Inject a protocol, closure, or value
   fixture at the existing architectural seam; do not redesign production
   layers only for Preview convenience.
4. Make fixtures deterministic and synthetic/non-sensitive: fixed identifiers,
   clock/date, locale, calendar, time zone, ordering, images, and success/failure
   outcome when those affect pixels or interaction. Never copy real account,
   message, location, health, contact, credential, or customer data into Preview.
5. Render the smallest relevant matrix in Xcode. A full screen commonly needs a
   baseline plus risk-relevant appearance, Dynamic Type, width, or state
   variants; a small component may need fewer.
6. Privacy-scan the rendered state, then capture a labeled canvas screenshot for
   human review. Record preview name, source/diff identity, Xcode build,
   device/trait configuration, and fixture; do not publish from this review step.
7. Apply feedback to the acceptance decision and the affected fixture or motion
   spec. Durable workflow improvement is a reviewed repository change, never an
   unreviewed self-modifying rule.
8. After visual approval, run only the integration/build/runtime evidence that
   the changed contract requires.

A preview fixture may use bundled development assets or an isolated
ephemeral/in-memory Core Data or SwiftData store when the screen requires it;
recreate that state per Preview. It must never reach a live network endpoint,
mutable shared or production disk/database/store, production CloudKit or
Keychain, analytics, notification delivery, account, signing, upload, or other
external side effect. Preview-only data must not become an alternate production
behavior path.

## SwiftUI and UIKit/AppKit boundaries

- SwiftUI: prefer `#Preview` when the selected compiler supports it. Keep content
  state explicit and inject production dependencies outside the pure rendering
  view. Use `@Previewable` only for SwiftUI dynamic properties and only when the
  current toolchain supports it.
- UIKit/AppKit: `#Preview` can return a view or view controller on supported
  toolchains. Preserve real containment, trait, lifecycle, and layout behavior;
  do not wrap the production screen in SwiftUI merely because it is convenient.
- Older project/toolchain: retain its compatible preview mechanism. Do not bump
  compatibility settings or mix framework architectures just for this skill.
- Shared rule: fixture implementations are inert and finite. They must never
  silently fall through to a live production dependency.

## Interaction and motion contract

Before adding custom motion, write down:

- trigger and semantic purpose;
- stable start, intermediate, settled, cancellation, and reversal states;
- relationship to the person's gesture or system transition;
- timing/curve or spring parameters justified by the interaction, not a global
  duration constant;
- what remains perceivable without motion;
- Reduce Motion behavior and any cross-fade/static alternative.

Use system components and transitions first. Apply the Disney 12 principles as
a selective critique vocabulary, not a checklist to force into every control.
Apple's HIG, platform conventions, task clarity, comfort, and accessibility
override decorative animation. Read the principle-to-interface mapping in the
[review contract](references/preview-and-motion-contract.md).

SwiftUI reads `accessibilityReduceMotion`. UIKit reads
`UIAccessibility.isReduceMotionEnabled` and responds to
`reduceMotionStatusDidChangeNotification` when the screen can remain alive
across a setting change. AppKit reads
`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` and observes
`accessibilityDisplayOptionsDidChangeNotification`. A non-SwiftUI watchOS path
uses `WKAccessibilityIsReduceMotionEnabled()` and
`WKAccessibilityReduceMotionStatusDidChange`. Avoid motion as the only carrier
of state, meaning, success, or failure.

## Evidence ladder

Treat each layer as a different claim:

| Evidence | Proves | Does not prove |
| --- | --- | --- |
| canvas render | one fixture renders in one recorded configuration | app build, launch, integration, or accessibility |
| canvas screenshot | point-in-time design review | runtime acceptance or motion |
| interactive canvas review | a preview seam can respond in that canvas | full app navigation, persistence, or device behavior |
| affected target build | selected code compiles for the recorded tuple | requested screen or interaction works |
| runtime screenshot | the prepared app state was visible | motion sequence or hidden functional assertions |
| trimmed runtime recording | the recorded interaction and motion occurred | unrelated flows or unasserted internal state |

Preview success is not build, install, launch, integration, accessibility, or
test success. Route static final evidence and trimmed recordings to `screenshot`,
functional selection to `apple-platform-testing`, and official build/run work to
`xcodebuild`. For motion, begin immediately before the trigger and end after the
settled state; exclude Home, launch, setup, unrelated navigation, and idle tail
unless they are the acceptance target.

## Proportional ten-lens contract review

Before handoff, assess the ten lenses in the
[review contract](references/preview-and-motion-contract.md): authority, source,
fixture isolation, state sufficiency, framework lifecycle, adaptive layout,
semantic accessibility, motion behavior, evidence meaning, and integration/
delivery. Authority and evidence meaning always apply; mark unaffected lenses
not applicable rather than creating work. A failed applicable lens returns to
one focused correction; it does not trigger a blind preview-build loop.

## Handoff

Report the reviewer question, chosen preview matrix and omissions, fixture seam,
approved/rejected screenshots, motion and Reduce Motion behavior, exact evidence
level achieved, feedback incorporated, and remaining runtime/test work. Do not
call a preview-only design complete for an existing app feature.
