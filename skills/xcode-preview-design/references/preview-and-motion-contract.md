# Preview and Motion Review Contract

Use this contract to keep code-first design fast without turning Xcode Preview
into a substitute for production integration or runtime evidence.

## Official source order

Use the selected Xcode toolchain and live Apple documentation before remembered
API availability or third-party examples:

1. [Previewing your app's interface in Xcode](https://developer.apple.com/documentation/xcode/previewing-your-apps-interface-in-xcode)
   defines the canvas, interactive mode, and SwiftUI/UIKit/AppKit preview route.
2. [Adding previews to your interface files](https://developer.apple.com/documentation/xcode/adding-previews-to-your-interface-files)
   documents `#Preview`, traits, sample data, and the SwiftUI-only boundary of
   `@Previewable`.
3. [SwiftUI previews in Xcode](https://developer.apple.com/documentation/swiftui/previews-in-xcode)
   is the current SwiftUI API index.
4. [HIG Motion](https://developer.apple.com/design/human-interface-guidelines/motion)
   requires purposeful, brief, cancellable, optional motion and favors familiar
   system behavior.
5. [HIG Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
   covers comfort and Reduce Motion expectations.
6. [SwiftUI `accessibilityReduceMotion`](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion)
   exposes the system preference to SwiftUI.
7. [UIKit `UIAccessibility`](https://developer.apple.com/documentation/uikit/uiaccessibility)
   exposes Reduce Motion state and change notification to UIKit.
8. [AppKit `accessibilityDisplayShouldReduceMotion`](https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayshouldreducemotion)
   and [display-options notification](https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayoptionsdidchangenotification)
   expose the macOS preference and live changes.
9. [WatchKit `WKAccessibilityIsReduceMotionEnabled()`](https://developer.apple.com/documentation/watchkit/wkaccessibilityisreducemotionenabled%28%29)
   and [its status notification](https://developer.apple.com/documentation/watchkit/wkaccessibilityreducemotionstatusdidchangenotification)
   cover non-SwiftUI watchOS interfaces.
10. [Controlling animation timing and movement](https://developer.apple.com/documentation/swiftui/controlling-the-timing-and-movements-of-your-animations)
   documents phase and keyframe animators when a standard animation is
   insufficient.

[Walt Disney Animation's animation process](https://www.disneyanimation.com/process/animation/)
is conceptual provenance for several classical principles. It is not Apple UI
guidance and never overrides platform behavior or accessibility.

## Ten review lenses

Authority and evidence meaning always apply. For the other lenses, record pass,
failed observation, or not applicable in proportion to the changed contract; do
not create ten deliverables or a full audit for a small component.

1. **Authority** — Exact repository, opened Xcode container, selected toolchain,
   deployment targets, and platform are known; no alternate checkout or toolchain
   was chosen to make Preview pass.
2. **Design source** — Repository/product requirements are primary unless the
   user supplied an exact Figma frame. Figma is optional and no approximate web
   preview is represented as Xcode fidelity.
3. **Fixture isolation** — Every dependency is finite and deterministic. Bundled
   development assets or a per-Preview ephemeral/in-memory store are allowed;
   no live endpoint, mutable shared/production store, CloudKit container,
   Keychain, analytics, notification delivery, account, credential, signing, or
   upload path can be reached.
4. **State sufficiency** — The matrix contains the changed state and only
   plausible visual boundaries: for example content plus the one affected
   loading/empty/error, appearance, width, locale, or Dynamic Type case.
5. **Framework lifecycle** — SwiftUI identity/state or UIKit/AppKit containment,
   traits, lifecycle, and layout are representative. A bridge is not introduced
   solely to manufacture a preview.
6. **Adaptive layout** — Relevant safe areas, orientation/window width, content
   growth, contrast, RTL/localization, and platform input are reviewed without a
   Cartesian-product matrix.
7. **Semantic accessibility** — Labels, values, traits, focus/order, hit region,
   Dynamic Type, contrast, and non-motion communication remain correct. Test-only
   identifiers do not replace accessible semantics.
8. **Motion behavior** — Purpose, trigger, gesture relationship, timing, settled
   state, interruption, cancellation/reversal, repeat behavior, and Reduce
   Motion alternative are explicit.
9. **Evidence meaning** — Canvas capture is labeled design-review evidence;
   screenshots do not claim motion; a trimmed runtime recording does not claim
   unasserted logic or another platform.
10. **Integration and delivery** — The smallest affected build/runtime/test is
    selected, omissions and residual risk are stated, and publication/PR actions
    remain under their existing authorization gates.

## Deterministic fixture contract

Prefer a pure presentation value when the view only needs pixels. Use a mock
protocol or closure when interaction needs a response. The mock returns a fixed
result or an explicitly selected failure and must never fall back to a live
implementation.

Stabilize only values that affect the review: synthetic IDs, clock/date,
calendar/time zone, locale, ordering, image dimensions/content, feature flags,
permissions, and async outcome. Never use real account, message, location,
health, contact, credential, or customer data. Avoid arbitrary delays. If loading
duration itself matters, control it with an explicit test clock or state
transition rather than wall time.

Keep fixtures in the repository's existing preview/test-support location. If no
convention exists, keep their visibility narrow and clearly preview-only; do not
add a production environment switch that can expose mock behavior in a release.
When persistence is essential to rendering, recreate an isolated in-memory or
ephemeral store for the Preview; never open or mutate a shared production store.

## Minimum-sufficient state matrix

Start with the exact state under review, then add a variant only when it can
change the decision:

| Risk | Candidate variant |
| --- | --- |
| semantic colors/materials | light and dark appearance |
| wrapping/truncation/layout | one large accessibility text size |
| adaptive composition | one materially different width/orientation |
| bidirectional layout | one affected RTL locale |
| async status UI | only changed loading, empty, failure, or content states |
| platform-specific view | one preview per affected platform implementation |
| motion comfort | normal and Reduce Motion behavior |

Do not multiply every row together. A tiny isolated component can have one or
two previews; a new full screen commonly needs baseline, dark appearance, and a
large-text or narrow-width boundary.

## Disney 12 principles adapted for interfaces

Use only principles that improve meaning, continuity, or feedback. Do not force
all 12 principles into one interaction.

| Classical principle | Interface adaptation | Guardrail |
| --- | --- | --- |
| Squash and stretch | restrained press/impact deformation | preserve legibility, hit region, and perceived weight |
| Anticipation | immediate pressed/focused state before an outcome | never delay the requested action for decoration |
| Staging | keep the changed object and result visually clear | do not dim or move unrelated content excessively |
| Straight ahead / pose to pose | define explicit state poses; reserve continuous simulation for gesture-led motion | prefer reproducible state-driven UI |
| Follow-through and overlap | let secondary parts settle after the primary state | settled state must arrive promptly and be interruptible |
| Slow in and slow out | use easing/springs that clarify arrival and departure | linear motion remains valid when constant rate conveys truth |
| Arcs | follow natural spatial paths when direction communicates origin/destination | do not add a curved path without semantic benefit |
| Secondary action | add subordinate feedback such as a symbol or haptic | it cannot compete with or replace the primary result |
| Timing | encode urgency, weight, causality, and distance | derive from task/system behavior; avoid a global duration rule |
| Exaggeration | gently amplify rare or important feedback | avoid repeated, startling, or accessibility-hostile motion |
| Solid drawing | preserve geometry, depth, occlusion, and touch continuity | avoid impossible layer changes that disorient people |
| Appeal | make state and affordance coherent and inviting | clarity, convention, and accessibility win over novelty |

## Motion verification

Review interactive Preview for rapid iteration, including interruption and
reentry when the canvas supports the path. Then verify the acceptance path in the
running app when motion is part of product behavior. Preview-only async,
navigation, keyboard, persistence, scene, and lifecycle behavior is not enough.

Normal-motion and Reduce Motion states must communicate the same outcome. Prefer
a short fade, color/symbol/state change, or immediate transition where spatial,
depth, blur, bounce, or repetitive movement would be uncomfortable. Do not add
animation merely to demonstrate that the framework can animate.

For review, a canvas screenshot records composition only. For delivery, use a
trimmed runtime recording that starts at the stable precondition immediately
before the trigger and ends after the result settles. Keep the raw recording,
publish the reviewed trim, and route artifact integrity/privacy checks through
`screenshot`.
