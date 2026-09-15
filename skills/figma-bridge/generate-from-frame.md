# Generating SwiftUI from a Figma frame

Use `get_design_context` to read the selected node, then implement the native
view. Inspect the active provider's schema and required skill first. Returned
reference code is context, not a guarantee of compiling SwiftUI.

## The whole flow

1. **Get the URL.** Engineer pastes the Figma frame URL: `https://www.figma.com/design/<fileKey>/<file>?node-id=42-7`.
2. **Read context.** Use `get_design_context` for the exact file/node. Supply a framework hint only through a supported field. Surface access failures.
3. **Narrow when necessary.** For truncated or oversized context, use `get_metadata` to select relevant children and fetch those.
4. **Measure, then implement.** Read each node's bounds from `get_metadata`
   and derive sibling gaps, alignment and the *visual* size of every glyph
   before writing modifiers; the returned reference code is not the spec.
   Translate that geometry into the project's SwiftUI/UIKit conventions and
   reuse mapped components. For a control whose exported glyph is small
   (roughly 12–24 pt), keep the glyph at design size, grow the tappable frame
   to ≥44 pt with insets/padding/`contentShape`, then subtract that inset from
   the outer spacing so the glyph still lands on its Figma coordinate; re-check
   the neighboring gaps after the adjustment.
5. **Write to the owning file.** Follow the actual project structure and existing screen, rather than inventing a `Views/` directory.
6. **Add the `// figma:` code-connect-map comment** at the top of the file ([`code-connect-map.md`](code-connect-map.md)).
7. **Hand off to `apple-platform-ui`** for the bounded production-view polish — semantic colors where the design leaves the color open, Dynamic Type, architecture-compatible state boundaries, and SF Symbol substitution where the design uses a system glyph. Add `xcode-preview-design` only when Preview or motion review is requested; route snapshot tests and pixel/text parity reports to `figma-golden-testing`.

## Assets: exported artwork, not catalog names

When the design provides an icon or image asset, the exported artwork is the
contract. `get_design_context` returns download URLs for each asset; add the
export (SVG or PDF, following the project's existing asset format) to the asset
catalog instead of substituting an SF Symbol or reusing whatever catalog entry
has a similar name. An existing asset is only acceptable after you render it and
compare it with the export — names lie: a `_dark` suffix usually means *for dark
backgrounds* (light artwork), and a `settings` asset may be a different glyph.
Keep colored exports in original rendering mode; use template rendering plus a
tint only when the design defines the color separately from the shape.

System control chrome is part of the same check. Toolbar and bar-button items
may receive an SDK-default background or shape that the flat design does not
show; when you opt out (for example `.buttonStyle(.plain)`), verify that the
label color did not fall back to the primary color — set the design's
foreground color explicitly.

## Colors: read the value, never judge it

A color is a property you look up, not a shade you recognize. For every fill,
stroke, text color, shadow and gradient stop in the node you are implementing,
read the actual value out of the design source before writing a modifier:

- `get_variable_defs(fileKey)` for anything bound to a variable or color
  style — bind to the token, and map it once to an asset-catalog color so the
  design system stays one edit wide.
- `get_design_context` for the node's own fills and strokes when it is not
  bound to a token. Carry the opacity with it; a 30%-alpha black track is not
  a gray, and writing the gray loses the layer underneath.

Never name a color from a rendered screenshot, from the component's name, or
from what it looks like next to something else. "Looks blue" is not `#2260DC`,
and a design's near-black is usually not `.primary`. If you cannot read the
value for a node, say the value is unresolved and ask — do not approximate it
and move on.

**Tint is a resolved value, not a modifier you wrote.** A template-rendered
asset, `.buttonStyle`, `.foregroundStyle`, a `List`/toolbar container, and the
enabled state each re-resolve the color that actually paints. Setting a tint is
not evidence it applied: a `.buttonStyle(.plain)` button drops the inherited
tint and paints its label in the primary color, and a template asset with no
explicit tint inherits whatever the container supplies. Set the design's color
explicitly on the element that paints it, then confirm the rendered pixel —
`figma-golden-testing` samples the capture, which is the only proof that the
color you wrote is the color that shipped.

The same rule covers the appearance axis: read the design's dark-mode values
when the file defines them, rather than assuming the light value inverts.

## Avoid large frames — the rule and the recovery

Large selections can truncate or exceed a provider's response budget. Diagnose
the actual response; pixel dimensions alone are not a fixed failure threshold.

**The rule:** start with the smallest frame that captures the design unit you want.

- Want one button → select the Button component, not the page.
- Want one card → select the Card component, not the screen that contains 12 cards.
- Want a whole screen → select the screen frame, not the page with 8 screens on it.
- Want a flow (3 screens together) → generate each screen separately, compose in `NavigationStack` after.

**The recovery if it refuses:**

1. Use `get_metadata` to walk the node's children. Find the largest meaningful sub-frame.
2. Generate from the sub-frame.
3. Repeat for each sibling.
4. Compose the parent layout by hand (it's just a `VStack` / `HStack` arranging the generated pieces).

Reference: https://developers.figma.com/docs/figma-mcp-server/avoid-large-frames/

## What the generated SwiftUI looks like — and what's missing

Use the design payload and screenshot to assess structure, typography and assets.
The agent authors and verifies the native draft; do not assume returned web code
or unsupported effects map directly to native components.

What it does **not** do well — these are why you hand off to `apple-platform-ui`:

| Missing | Why `apple-platform-ui` adds it |
|---|---|
| Minimum risk-relevant Preview matrix | `xcode-preview-design` selects only states that can change the review decision |
| Architecture-compatible state boundary | `apple-platform-ui` preserves or narrows the project's existing seam |
| Semantic `Color.primary` / `.secondary` / `.systemBackground` — only where the design leaves the color open | A semantic color is a substitution, so it applies where the design did not fix a value. Where the file specifies a fill, stroke or token, that value is the contract; carry it into the asset catalog with its dark-mode variant instead of swapping in a system color |
| SF Symbol substitution for system glyphs | Figma layers that reproduce a system glyph (`icon/chevron.right`) → `Image(systemName: "chevron.right")`; design-system icons keep their exported artwork |
| Deterministic fixture seam | Prefer a value; reuse a protocol or closure only when interaction needs it |
| 44pt tap target audit | `apple-platform-ui` checks every `Button` / `.onTapGesture` |
| Dynamic Type readability | `apple-platform-ui` confirms accessibility3 doesn't truncate |

So a typical sequence is:

```
get_design_context  →  ProfileView.swift (unverified native draft)
       ↓
apple-platform-ui  →  production view refined without gratuitous architecture changes
       ↓
xcode-preview-design  →  minimum Preview matrix and optional motion review
       ↓
xcodebuild/runtime evidence  →  verify on the selected affected destination
       ↓
screenshot (when acceptance needs it)  →  capture the as-built state or trimmed motion
```

## Re-generating an existing view

When the designer updates the frame, the engineer comes back wanting to refresh `ProfileView.swift`. **Don't blast over the existing file** — the developer has likely added wiring (UseCase injection, accessibility identifiers, view-model bindings) that aren't in Figma.

The safe loop:

1. Generate the new draft into a *temp file* — `Views/__tmp/ProfileView.swift`.
2. Diff against the live `ProfileView.swift`.
3. Apply only the visual changes (layout, colors, fonts, spacing). Leave the wiring alone.
4. Update the `// figma:` comment if the node-id changed.
5. Delete the temp file.

This is the kind of careful merge work that's worth doing by hand or with `apple-platform-ui`'s help, not a one-shot regenerate.

## Variables and tokens

If the Figma file uses variables (and it should — see [`figma-review.md`](figma-review.md) section 5), pull them with `get_variable_defs(fileKey)` and emit a Swift `Theme` enum once per project:

```swift
enum Theme {
    static let backgroundPrimary = Color("backgroundPrimary")   // from figma var
    static let textPrimary       = Color("textPrimary")
    static let spacingMd: CGFloat = 16
    static let radiusMd: CGFloat = 12
}
```

Map the asset catalog colours to the Figma variable names directly. Now every generated view references `Theme.backgroundPrimary` instead of a hex literal, and a design-system colour change is a one-line edit.

## Working with screenshots when MCP isn't enough

Sometimes `get_screenshot(fileKey, nodeId)` is more useful than `get_design_context`:

- For visual diff after build — render the as-built view, fetch the Figma screenshot, and compare through `figma-golden-testing`; a glance at a downscaled preview is not verification.
- For micro-interactions the MCP doesn't expose (subtle shadows, gradient stops not yet wired to variables) — read the screenshot for ground truth.

Use a screenshot only when it answers the exact source-parity or acceptance
question; repeated captures without a changed hypothesis add noise.

## Self-review before saying "generated"

- [ ] Compile or Preview claims come from the official Xcode path; mental rendering is planning, never evidence.
- [ ] `// figma:` comment at the top points at the exact node generated from.
- [ ] Every fill, stroke, text and tint colour was read from `get_variable_defs` or the node's own properties — none was named by eye, and none of the design's specified values was swapped for a semantic colour.
- [ ] Colours bound to a Figma variable are bound to the matching token, not pasted as hex.
- [ ] The rendered tint was confirmed on the element that paints it, not assumed from the modifier written.
- [ ] No empty `VStack {}` or `Spacer()` artefacts left from un-rendered nodes.
- [ ] Design-system icons come from the Figma export (rendered and compared), not from a same-named catalog asset or an SF Symbol.
- [ ] Every small-glyph control has a ≥44 pt frame and its glyph still sits on the Figma coordinate after the inset.
- [ ] Routed to `apple-platform-ui` for the HIG polish (or told the engineer to).

## Self-review when a generate call fails

- [ ] Frame size checked first — was the error "too large"?
- [ ] Tried with a smaller child node — did that succeed?
- [ ] If still failing, surfaced the specific error to the engineer (don't keep retrying blindly).
- [ ] Suggested the matching `figma-review.md` section if the file is structurally broken (no Auto Layout, raw groups, mega-frames).

## References

- **Design read/write tool roles** → https://developers.figma.com/docs/figma-mcp-server/tools-and-prompts/
- **Avoid large frames** → https://developers.figma.com/docs/figma-mcp-server/avoid-large-frames/
- **All MCP tools** → https://developers.figma.com/docs/figma-mcp-server/tools-and-prompts/
- **Figma + Codex: use cases** → https://developers.openai.com/codex/use-cases/figma-designs-to-code
