# Optional: inspect previews with XRay

[XRay](https://github.com/ShawnBaek/XRay) is an MIT-licensed Swift package for
iOS and iPadOS, maintained by this collection's author. It runs inside Apple's
preview canvas; it does not replace the canvas or
[`RenderPreview`](xcode-mcp-render.md). It adds:

- outlines and captions naming each rendered UIKit view class (a controller's
  root view shows the controller), the previewed SwiftUI view, and each nested
  SwiftUI view type registered with `.xrayView()`, to answer which type draws a
  region of a large or unfamiliar screen;
- `.preview(xray:reference:configuration:)` on a SwiftUI view, `UIView` or
  `UIViewController`: a per-preview inspection switch plus an offline
  comparison with a saved design image behind a draggable divider;
- `capture()` and `hierarchy()` for an annotated image and the type hierarchy.

The divider comparison is a design review aid, not a parity gate. For a
node-specific Figma contract use [`figma-golden-testing`](../../figma-golden-testing/SKILL.md),
and for evidence use the [aligned comparison](../../screenshot/references/aligned-comparison.md).

## Adopt it deliberately

- **Approval.** To the project, XRay is a third-party dependency like any
  other; that this collection's author maintains it is no reason to add it.
  Add it only when the project already uses it or the person approves it under
  the project's dependency policy.
- **Version.** Depend on a release,
  `.package(url: "https://github.com/ShawnBaek/XRay.git", from: "2.0.0")`, and
  add its `XRay` library product to the app target. 2.0.0 is the first release
  with `.preview(xray:)`; 1.x tags carry the older screenshot-observer API, and
  a `from: "1.0.0"` requirement resolves only below 2.0.0, so it never reaches
  the preview API.
- **Requirements.** XRay 2.0.0 needs iOS or iPadOS 17 and supports no other
  platform; in a multiplatform target, link it for iOS only. Its manifest
  declares Swift tools 6.0, so resolving it needs Xcode 16 or later. Never
  raise a deployment target to adopt it.
- **Release builds.** XRay installs nothing in Release, and `.preview()` there
  shows the content without controls, but the package is still linked into
  every configuration of a target that depends on it. Keep `import XRay` and
  the XRay previews inside `#if DEBUG`, as XRay's documentation advises. Leave
  it out when the project forbids debug tooling in shipped binaries.
- **Reference images.** A `.resource("<name>", bundle:)` reference reads
  `XRayReferences/<name>/reference.png` and `metadata.json` from the bundle you
  pass; `#if DEBUG` does not remove copied resources. In an Xcode target, list
  that folder in the target's Development Assets (`DEVELOPMENT_ASSET_PATHS`) so
  archives exclude it. A Swift package's `.copy("XRayReferences")` resource is
  not excluded that way and needs its own packaging decision. Verify the built
  product either way. Commit only approved design exports, never app captures
  with personal data, and keep private design references out of public
  repositories.
- **Design sync.** XRay's separate macOS sync tool exports a reference from the
  Figma Desktop app's local MCP server, in the person's signed-in session; it
  has no token or remote fallback, and its snapshot is not pinned to a Figma
  file version. It is not a product of the package dependency: run it from a
  clone of the XRay tag the project depends on, as its README describes. The
  person confirms the account, file and node in Figma Desktop first; see
  [`figma-bridge`](../../figma-bridge/SKILL.md) for the Figma side. Rendering
  itself stays offline.

## Use it in the preview loop

- Keep a plain `#Preview` for each evidence state and add XRay previews as
  extra inspection entries. The overlay and floating controls are part of the
  rendered content, so a canvas screenshot or `RenderPreview` snapshot of an
  XRay preview is an inspection image, not a clean render.
- XRay does not disable services. The fixture rules in the skill still apply.
- Label the result in the [evidence ladder](../SKILL.md#evidence-ladder): an
  annotated `capture()` image is a point-in-time canvas screenshot; the divider
  comparison and other live interaction are interactive canvas review.
