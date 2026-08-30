# Generating SwiftUI from a Figma frame

The `generate_figma_design` MCP tool turns a selected Figma node into framework code (SwiftUI for this skill; the same tool can emit React, Vue, etc. for web). It's the highest-value MCP call in the whole workflow — but the one that fails most often if you call it carelessly.

## The whole flow

1. **Get the URL.** Engineer pastes the Figma frame URL: `https://www.figma.com/design/<fileKey>/<file>?node-id=42-7`.
2. **Check it's reachable.** `get_metadata(fileKey, nodeId)` returns size + type + name. If 404 / unauthorized, surface to the engineer.
3. **Check the size budget.** If the node is too big (≈ multiple screens of content), `generate_figma_design` will refuse. See "Avoid large frames" below — pick a smaller child node instead.
4. **Generate.** `generate_figma_design(fileKey, nodeId, framework: "swiftui")` returns Swift code.
5. **Write to the right file.** New screen → new file in `Views/`. Existing screen → ask the engineer where to insert.
6. **Add the `// figma:` code-connect-map comment** at the top of the file ([`code-connect-map.md`](code-connect-map.md)).
7. **Hand off to `apple-platform-ui`** for the bounded production-view polish — semantic colors, Dynamic Type, architecture-compatible state boundaries, and SF Symbol substitution. Add `xcode-preview-design` only when Preview or motion review is requested.

## Avoid large frames — the rule and the recovery

The MCP server has a context window. A 4096×9000 px frame full of nested content overflows it. When this happens, `generate_figma_design` returns an error like "frame too large for context" and produces nothing.

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

`generate_figma_design` emits structurally-faithful SwiftUI: `VStack`/`HStack`/`ZStack` matching the Figma Auto Layout, `Text` with the right font / weight / size, `Image`s referencing layer names, colour values pulled from styles where mapped (raw hex otherwise).

What it does **not** do well — these are why you hand off to `apple-platform-ui`:

| Missing | Why `apple-platform-ui` adds it |
|---|---|
| Minimum risk-relevant Preview matrix | `xcode-preview-design` selects only states that can change the review decision |
| Architecture-compatible state boundary | `apple-platform-ui` preserves or narrows the project's existing seam |
| Semantic `Color.primary` / `.secondary` / `.systemBackground` | Generated code uses literal hex; semantic colors handle dark mode |
| SF Symbol substitution | Figma layers named `icon/chevron.right` → `Image(systemName: "chevron.right")` |
| Deterministic fixture seam | Prefer a value; reuse a protocol or closure only when interaction needs it |
| 44pt tap target audit | `apple-platform-ui` checks every `Button` / `.onTapGesture` |
| Dynamic Type readability | `apple-platform-ui` confirms accessibility3 doesn't truncate |

So a typical sequence is:

```
generate_figma_design  →  ProfileView.swift (first draft, ~80% structurally right)
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

- For visual diff after build — render the as-built view, fetch the Figma screenshot, eyeball.
- For micro-interactions the MCP doesn't expose (subtle shadows, gradient stops not yet wired to variables) — read the screenshot for ground truth.

Use a screenshot only when it answers the exact source-parity or acceptance
question; repeated captures without a changed hypothesis add noise.

## Self-review before saying "generated"

- [ ] Compile or Preview claims come from the official Xcode path; mental rendering is planning, never evidence.
- [ ] `// figma:` comment at the top points at the exact node generated from.
- [ ] No raw hex colours where a semantic / variable colour was available.
- [ ] No empty `VStack {}` or `Spacer()` artefacts left from un-rendered nodes.
- [ ] Routed to `apple-platform-ui` for the HIG polish (or told the engineer to).

## Self-review when a generate call fails

- [ ] Frame size checked first — was the error "too large"?
- [ ] Tried with a smaller child node — did that succeed?
- [ ] If still failing, surfaced the specific error to the engineer (don't keep retrying blindly).
- [ ] Suggested the matching `figma-review.md` section if the file is structurally broken (no Auto Layout, raw groups, mega-frames).

## References

- **`generate_figma_design` tool docs** → https://developers.figma.com/docs/figma-mcp-server/tools-and-prompts/#generate_figma_design
- **Avoid large frames** → https://developers.figma.com/docs/figma-mcp-server/avoid-large-frames/
- **All MCP tools** → https://developers.figma.com/docs/figma-mcp-server/tools-and-prompts/
- **Figma + Codex: use cases** → https://developers.openai.com/codex/use-cases/figma-designs-to-code
