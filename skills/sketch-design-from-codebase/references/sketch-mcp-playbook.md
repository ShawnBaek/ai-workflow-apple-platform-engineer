# Sketch MCP playbook

Behaviors observed with Sketch 2026.x, JS API 2.0, through the Sketch MCP.
The official guides (`get_guide` topics `mcp`, `use`, `layout`, `styling`,
`symbols`, `assets`) remain the API reference; this page records where the
documented path did not work and what did.

## Session and document

- `new sketch.Document()` creates and selects a document; keep using
  `sketch.getSelectedDocument()` in every script. `Document.all()` is not
  available.
- Save early: `doc.save('/abs/path/File.sketch', cb)`. After a save-as the
  document identifier changes; re-read it from `sketch.getSelectedDocument().id`
  before calling `get_screenshot` or `get_symbol_overrides`.
- Close a previous document only after saving it (`doc.save(cb)` then
  `doc.close()` inside the callback); an unsaved close prompts and stalls the
  bridge.
- The bridge times out on scripts that run longer than roughly thirty seconds.
  A timed-out script has usually still applied; verify with
  `get_document_info` instead of re-running it. Do not run two heavy scripts
  in parallel; after a timeout, wait a few seconds before the next call. A
  "Server unavailable" reply is transient while Sketch itself is idle; the
  desktop connector reports `connected` and calls succeed again shortly.
- Prefer one screen per script with small helper functions. Scripts cannot
  read the file system (`@skpm/fs` is not a core package) — pass file paths
  to `sketch.Image` and put text data inline.

## Layers and text

- Always set `style.fontFamily` (for example `'SF Pro'`); the default is not
  the system font. Weights: 5 regular, 6 medium, 7 semibold, 8 bold.
- Multi-line text: set `fixedWidth = true` and `frame.width` after creation;
  auto-width text ignores the given width and overflows.
- `frame.height` of a text layer is stale right after creation; do not use it
  to lay out the next element. Estimate lines as
  `ceil(chars / floor(width / (size × 0.46)))` and use a line height of about
  1.3 × size.
- Resizing a `Group.Frame` after children exist scales the children. Compute
  the final height first, create the frame with it, then add children.
- Sketch resolves layers by name only for discovery; to edit, keep the layer
  identifiers from creation logs or find by exact `name` inside the known frame.
- Shared text styles pushed with a plain style object do not retain
  typography, and `SharedStyle.fromStyle` still reads back `fontSize`
  undefined; style text layers directly and keep the ramp on a Foundations
  frame as the documentation of record.
- `sketch.export(layer, { output, formats: 'png', scales: '2', overwriting:
  true })` writes `<layer name>@2x.png` into `output`.

## Images and icons

- `new sketch.Image({ image: '/abs/path.png', frame })` embeds the bitmap at
  creation; later edits to the file do not update the layer.
- `style.tint` on an image layer is not honored. Render each color variant.
- SVG: `createLayerFromData(svgString, 'svg')` needs the file contents, which
  scripts cannot read. Rasterize with `rasterize-logos.swift` and insert as PNG.
- SF Symbols: the Apple UI Kits ship symbol *glyphs as private-use text*, and
  neither the SF Symbols app metadata nor the SF Pro font exposes a
  name→codepoint table (glyph names are `uni10xxxx.medium`). Render symbols
  with `render-sf-symbols.swift`; it crops to the visible alpha box so the
  glyph centers correctly in buttons. Keep a manifest of point sizes and place
  icons by center: `x = cx − w/2`, `y = cy − h/2`.

## Apple UI Kit symbols

- Discover with `get_libraries`, then `get_design_assets(kind: 'symbol',
  sourceLibraryID, nameContains)`; full listings exceed the tool limit, so
  search by category (`Tab Bars`, `Toolbars/Light/iPhone`, `Status Bars`,
  `Home Indicators`, `Sheets`, `Windows`, `Sidebars`, `Navigation Bars/49mm`).
- Import once onto a Foundations page as templates, configure, then
  `duplicate()` into each screen and reparent; set `frame.x/y` after
  reparenting.
- Overrides: `instance.overrides.find(o => o.id === prefix + '_' + prop)`,
  where `prefix` is the `commonOverrideIDPrefix` from `get_symbol_overrides`.
  Useful props: `stringValue`, `isVisible`, `textColor`, `color:fill-N`,
  `opacity:fill-N`, `symbolID`. Blank a glyph with `' '` and overlay a rendered
  icon when the kit glyph is wrong.
- A duplicated instance does not keep a manually set width when the master
  uses fit sizing; set `frame.width` again after duplication.
- Kit tab bars mark the first tab as selected through a nested symbol with a
  glass fill. Fill/opacity/`symbolID` overrides on that nested layer did not
  remove the highlight; cover it with a bar-colored patch and draw the real
  selected pill on top.
- **Measure kit geometry** instead of estimating from screenshots: duplicate
  the instance, `detach({ recursively: true })`, walk the layers for the
  button and tab frames, log them, remove the copy. Observed for the iOS 27
  iPhone kit: toolbar trailing button center (364, 22) inside a 402-wide bar
  (so (364, 84) below a 62 pt status bar); sheet toolbar trailing (365, 38);
  tab centers x = 72, 158, 244, 330 with the selection pill at x 25–119,
  y 20–74 of the 99 pt bar. Re-measure when the kit version changes.
- Status bars carry an `AppName` text override (`Stack/App Menu/Menu`) on
  iPad; set it to the app's name.

## Verification loop

- `get_screenshot(layerID)` after each screen; inspect for clipped text,
  overlapping rows, icons invisible against their background, and overlay
  drift. Fix in a targeted script rather than rebuilding.
- `get_layer_tree_summary` does not expand symbol instances; use the detach
  method above for internal geometry.
- Before commit: `get_document_info` to confirm every planned frame exists per
  page, then save.
