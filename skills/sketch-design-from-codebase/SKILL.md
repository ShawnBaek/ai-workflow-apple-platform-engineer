---
name: sketch-design-from-codebase
description: >-
  Create a Sketch design system and every screen of an existing iOS, iPadOS, macOS or watchOS app from its codebase, through the Sketch MCP. Use when the developer asks to "move the app into Sketch", document current screens as design, or redesign all screens in a reference style (for example "like the Uber app") while keeping the app's features and navigation. Chooses reproduction versus redesign first, derives screens, tokens, assets and copy from source and real captures, builds with Apple's UI Kit chrome, real SF Symbols and repo logos, verifies every frame by screenshot, and commits the .sketch file. Not for Figma sources (use figma-bridge) or for writing view code (use apple-platform-ui).
---

# Sketch design from a codebase

Produce a `.sketch` file that a designer or reviewer would accept as *the app*:
correct screen inventory and navigation per platform, real fonts, real system
chrome, real icons and logos, real copy and labels — not a wireframe drawn
from memory. Every visual claim in the file must trace to source code, an
asset in the repository, a real capture, or an approved style decision.

Sketch is driven only through the Sketch MCP (`get_guide`, `run_code`,
`get_document_info`, `get_layer_tree_summary`, `get_symbol_overrides`,
`get_screenshot`, `get_design_assets`, `get_libraries`). Load `get_guide`
topics `mcp` and `use` before the first mutation, then follow
[the MCP playbook](references/sketch-mcp-playbook.md) for the API behaviors
that differ from the documentation.

Preflight: this skill reads the app repository and writes one design file.
Building or capturing the app for reproduction is an Xcode action and starts
with `xcode-project-workflow`; the branch and commit for the saved `.sketch`
route through `git-workflow`. Sketch must be running with *Allow AI tools to
interact with open documents* enabled, and the Apple UI Kit libraries for the
target platforms added in Sketch's Libraries settings — a library the user
just added may not appear until the next `get_libraries` call. Never edit the
app's source from this skill.

## Decide the mode before drawing anything

Ask, in one round, which of these the developer wants; they produce different
files and cannot be blended:

| Mode | Ground truth | Result |
| --- | --- | --- |
| **Reproduction** | real captures of the running build + source | pixel-faithful screens of the app as it is today |
| **Redesign** | source (features, navigation, data) + an approved reference style | new visual system applied to the same screens and flows |
| **Documentation** | source only, when no build can run | labeled structural screens; say so in the file and the handoff |

A "styled wireframe" is not a third mode; a developer who asks for "the app
in Sketch" is asking for reproduction, and one who names a reference app is
asking for redesign. For redesign, run
[design discovery](../agent-harness/references/design-discovery.md) for the
reference and style, then write the token set (palette, type scale, radii,
chip/button/list idioms) on a Foundations page before any screen. Confirm
light/dark scope and whether system chrome stays native or becomes custom.

Build one representative screen first (the primary list or home screen),
export it as PNG, send it to the developer, and get an explicit yes before
fanning out to every screen. This checkpoint is cheaper than 40 rebuilt frames.

## Derive everything from the repository

Follow [the inventory method](references/codebase-inventory.md). In short:

1. **Screens and navigation per platform.** Enumerate top-level views per
   target (`NavigationStack`/`TabView` shells, `NavigationSplitView` for iPad,
   `HSplitView`/sidebar for macOS, vertical `TabView` pages for watchOS), the
   sheets and popovers they present, and child pickers. One frame per screen
   state the user can reach; include filter sub-pickers, editors, paywalls,
   onboarding pages and empty states that the code defines.
2. **Tokens.** Read the theme type (colors, fonts, spacing, radii) and the
   asset catalog `*.colorset/Contents.json` for exact light and dark hex.
   For redesign, keep these as the app's *current* tokens beside the new ones.
3. **Labels and data.** Enum raw values (filters, statuses), StoreKit product
   names and prices, formatter output shapes, and real content from captures
   or snapshot-test PNGs in the repo. Do not invent company names, prices or
   copy when the repository has them.
4. **Assets.** Company/brand logos and illustrations in the asset catalogs;
   rasterize SVG and PNG to a fixed point height with
   `scripts/rasterize-logos.swift`.
5. **Device sizes.** Take them from real capture pixel sizes divided by scale
   (for example 1206×2622 @3× → 402×874), not from memory.

For reproduction, capture the running build with
`xcrun simctl io <udid> screenshot` after driving it with the Xcode device
interaction tools; this works even when an agent-side Simulator panel is
broken. Place each capture as a locked reference layer under the rebuilt
frame and match it before removing or keeping it, as agreed.

## Build with real components

- **Fonts.** Set `fontFamily` to the platform font (`SF Pro`) on every text
  layer; Sketch defaults to Helvetica otherwise and the whole file reads wrong.
- **System chrome.** Import Apple's iOS/macOS/watchOS UI Kit symbols
  (status bars, toolbars, tab bars, home indicators, window controls,
  watch navigation bars) via `get_libraries` + `get_design_assets`, set their
  text, tint and visibility overrides, then measure their real geometry before
  placing anything on top of them (playbook: "Measure kit geometry").
- **Icons.** The kits do not expose SF Symbols as symbols, and there is no
  name→codepoint table on disk. Render the exact symbols with
  `scripts/render-sf-symbols.swift` (tinted, alpha-cropped, 3× PNG), keep a
  manifest of point sizes, and place them as image layers. Render every color
  variant you need; `style.tint` on an image layer is not honored.
- **Components.** Build cards, chips, rows, tags and buttons with small helper
  functions inside each `run_code` script so every screen uses one recipe;
  compute a container's final height *before* creating it (resizing a Frame
  scales its children).
- **Content.** Use the real labels, prices and sample data gathered above;
  keep private identifiers out of a file that may be shared.

## Verify and deliver

1. Screenshot every frame after its last edit; fix overlaps, clipped text,
   invisible icons (same color as background) and misaligned overlays before
   moving on. Compare against the capture in reproduction mode.
2. Save early with `document.save(path)` into the app repository (for example
   `docs/design/<App>-AllScreens.sketch`); the document identifier changes
   after a save-as, so re-resolve it. Save again after every platform.
3. Commit only the `.sketch` file on a task branch, note its size, and hand
   the developer per-platform PNG exports of the primary screen.
4. State what is approximate: estimated line wrapping, kit chrome tinted by
   overlay rather than override, data-dependent strings, omitted states.

When the design must become code, route to `apple-platform-ui`; for Preview
review, `xcode-preview-design`. This skill does not change the app.
