---
name: icon-composer
description: >-
  Design, author, inspect, and install Apple-platform app icons with Apple Icon
  Composer, layered SVG or PNG artwork, SF Symbols, SF Pro typography, Xcode
  .icon packages, legacy AppIcon asset catalogs, macOS .icns files, and opaque
  App Store exports. Use for iOS, iPadOS, macOS, or watchOS icon concepts;
  typography or monogram icons; Default, Dark, Clear, or Tinted appearances;
  Xcode app-icon replacement; platform-size generation; or archive icon
  verification.
---

# Icon Composer

Create recognizable Apple-platform app icons and wire the approved result into
Xcode. Prefer a simple concept-aware mark: a bold monogram or symbol, one clear
semantic cue, and a restrained product palette.

## Hard requirements

- Author every `.icon` package in the real Apple Icon Composer macOS app. Open,
  edit, preview, and save the package in Icon Composer before treating it as a
  deliverable.
- Never handcraft an Icon Composer package or `icon.json`. If Icon Composer is
  unavailable, stop before creating the `.icon` handoff.
- Use Icon Composer for Liquid Glass, refraction, blur, opacity, shadows,
  platform composition, and appearance annotations.
- Use another design tool or deterministic scripts only to prepare flat source
  layers, previews, contact sheets, fallback sizes, and opaque marketing PNGs.
- Before editing an Xcode project, invoke `xcode-project-workflow`. Use
  `xcodebuild` for build, simulator, bundle, and archive verification.

## Prepare the artwork

- Start from the latest template in
  [Apple Design Resources](https://developer.apple.com/design/resources/).
- Prefer SVG layers for scalable flat artwork. Use PNG when the artwork relies
  on SVG features Icon Composer doesn't support.
- Convert typography to outlines before SVG export because SVG doesn't preserve
  fonts reliably.
- Use SF Pro for typography-first icons. Resolve the installed Apple font on the
  current Mac instead of hardcoding another developer's font path.
- Use SF Symbols or an Apple platform rendering API for system symbols. Do not
  redraw an SF Symbol by hand.
- Keep colors, text, and graphics on separate, meaningfully named layers.
  Number layers from back to front, such as `01-background.svg` and
  `03-monogram.svg`.
- Keep source artwork flat and simple. Remove pre-rendered glass, blur,
  refraction, highlights, masks, and shadows that Icon Composer should add.
- Do not export the icon mask. Apple applies the platform crop automatically.

## Design rules

- Prefer a short two- or three-character mnemonic over a full app name.
- Use one meaningful cue for the product domain. Avoid several tiny symbols
  competing for attention.
- Read the app's theme, design tokens, asset catalog, and existing UI before
  choosing colors.
- Keep the core mark consistent across Default, Dark, Clear, and Tinted
  appearances so people can still recognize the app.
- Keep layer groups to four or fewer unless the design clearly needs more
  separation.
- Verify that the mark remains legible at 16, 32, 64, 128, and 256 px.
- Judge optical balance at actual icon size, not only while zoomed into the
  1024 px canvas.

## Workflow

1. Inspect the product concept, supported platforms, deployment targets,
   current app icon, Xcode icon settings, and brand colors.
2. Prepare separate flat SVG or PNG layers at the correct platform canvas size.
3. Open Icon Composer and import the layers in back-to-front order.
4. Tune groups, color, opacity, Liquid Glass, shadow, and composition in Icon
   Composer. Customize only the platform or appearance variants that need it.
5. Preview iOS/macOS and watchOS independently. Preview Default, Dark, and Mono;
   use Mono options to inspect Clear and Tinted results.
6. Save the editable design source with its variant name, then save the approved
   Xcode package with the canonical product name, using the `AppName.icon`
   pattern.
7. Export a 1024 px preview and a small-size contact sheet. Iterate until the
   icon reads clearly at every tested size.
8. Read [`platform-handoff.md`](./platform-handoff.md), install the correct
   artifact in every applicable target, and verify the built product.

## Source layout

Use a predictable layout while exploring variants, but give Xcode the canonical
app-name package:

```text
AppNameIcon/
  VariantName/
    SourceLayers/
      01-background.svg
      02-semantic-cue.svg
      03-monogram.svg
      AppName-Variant.icon
      AppName.icon
    Exports/
      AppName-Variant-preview-1024.png
      AppName-Variant-contact-sheet.png
      MacOSAppIcon.appiconset/
      AppName-AppIcon.icns
```

Keep the descriptive variant name in the design archive. Use `AppName.icon`,
not `AppName-Variant.icon`, as the Xcode app-icon package unless the developer
explicitly requests a different product name.

## Verification

- Inspect the actual `.icon` package in Icon Composer after saving it.
- Confirm source dimensions, layer order, supported platforms, and appearance
  overrides.
- Confirm any App Store or fallback 1024 PNG is RGB/sRGB, fully opaque, and has
  no alpha channel.
- Build every applicable platform target and inspect the icon on a simulator or
  device at small and large display sizes.
- Inspect the built app bundle for the expected generated icon resources.
- For macOS distribution, inspect a newly created archive. Never validate an
  icon change against an older `.xcarchive`.

## Do not

- Claim that a script-generated folder is an Icon Composer-authored `.icon`.
- Bake a rounded-rectangle or circular platform mask into the artwork.
- Replace a layered icon with a flat PNG without checking the project's
  deployment and fallback requirements.
- Assume a 1024 PNG alone is a complete legacy macOS icon set.
- Submit an App Store fallback PNG with transparency.
