# Reviewing a Figma file for developer-friendliness

Designers and engineers measure quality differently. A Figma file can look pixel-perfect to a designer and still be miserable to implement: raw groups instead of components, no auto-layout (so resizing breaks the design), inconsistent naming, frames so big the MCP server chokes, hex colours pasted in raw instead of using styles.

This is the audit you run on a Figma file **before** anyone tries to write code from it. Returns a punch list grouped by severity that the designer can act on. Saves the engineering team weeks of "actually, can you adjust…" tickets after build starts.

## When to run

- The designer says "the file's ready for handoff."
- A selected screen needs design-to-code implementation through `get_design_context`.
- A designer joins the team and you want to align on conventions.
- Every quarter on the design-system file — components rot fast.

## How to run (via the MCP server)

1. Get the file structure: `get_metadata(fileKey)` — walks pages, frames, components, variants without pulling pixel data. Cheap, complete.
2. For each component / page, score against the checklist below.
3. Return the punch list as a single message — grouped by severity, each item naming the specific Figma node and what to change.
4. **Optional:** post the punch list back as a Figma comment via the MCP server (designer sees it in the file, no email).

## The 7-section dev-friendliness checklist

### 1. Components, not groups (🔴 blocking)

Raw groups force the engineer to rebuild the design every time it's used. Components reuse, variants switch, mappings stick.

- [ ] Every recurring visual element (button, card, badge, avatar, list row) is a **Figma component**, not a group.
- [ ] Components live on a dedicated **Components page**, not scattered through screen designs.
- [ ] No two components do the same thing under different names (`Button`, `BtnPrimary`, `MainButton` — pick one).

**How to detect via MCP:** `get_metadata` returns `type: "COMPONENT"` vs `type: "GROUP"` for each node. Walk the page; flag any "looks like a button" group that isn't a `COMPONENT`.

### 2. Auto Layout coverage (🔴 blocking)

Without auto layout, the design breaks the moment text length or container width changes — which is every second on a real iOS device with Dynamic Type.

- [ ] Every frame containing text uses **Auto Layout** (vertical or horizontal direction).
- [ ] Padding is set on the frame, not via spacer rectangles.
- [ ] Text layers inside Auto Layout frames are set to **Fill container** for width when they should wrap.

**Hit rate matters.** A file where 60% of frames are auto-laid-out and 40% aren't will still break in 40% of cases. Aim for ~100% on screens, can be looser on illustrations / icons.

### 3. Variants over duplicates (🟠 high)

Three "Button - Primary - Default", "Button - Primary - Hover", "Button - Primary - Disabled" sibling components is a smell. They should be one component with a `state` variant property.

- [ ] Components with multiple visual states use **variants** (`state`, `size`, `icon`), not separate components.
- [ ] Variant property names match what the engineer will call them in code (`state` not `Status_Type`).
- [ ] Variant *values* are lowercase, snake-case-free (`primary`, not `Primary` or `primary_btn`).

### 4. Naming discipline (🟠 high)

Engineers grep for component names. "Frame 1248" is unfindable; `ProfileHeaderRow` is greppable, mappable in Code Connect, and self-documenting.

- [ ] No `Frame N` or `Group N` names anywhere — every node has a meaningful name.
- [ ] Component names use **PascalCase** (matches Swift type names): `ProfileHeader`, not `profile-header` or `profile_header`.
- [ ] Variant property values are lowercase: `Button / state=primary` not `Button / state=Primary`.
- [ ] Icons are namespaced: `icon/chevron.right`, `icon/heart.fill` — engineer can map directly to SF Symbol names.

### 5. Styles and variables, not raw values (🟠 high)

A hex value pasted into 80 layers becomes 80 places to fix when the brand colour shifts.

- [ ] Colours come from **color styles** or **variables**. No raw hex pasted into a layer.
- [ ] Text uses **text styles** (`Display/Large`, `Body/Regular`). No one-off font/size/weight combos.
- [ ] Spacing and radius use **number variables** if the team has a token system.
- [ ] Light + Dark are wired as **variable modes** on the same color variables, not as duplicate dark-mode pages.

**Why it matters:** `get_variable_defs(fileKey)` returns these as machine-readable tokens. The engineer maps them once to a Swift `Theme` enum and the whole codebase tracks the design system. Raw hex blocks this.

### 6. Frame size budget (🟡 medium — but blocks the MCP flow)

Large selections can exceed the provider's response budget. Use the observed
response and metadata to select smaller relevant frames; do not assume a fixed
pixel threshold or require restructuring the designer's file.

- [ ] Each screen is one frame, sized to the device viewport (iPhone 16 Pro: 393 × 852).
- [ ] Long scrollable screens are broken into stacked sub-frames (header, content, footer) on one parent, not one mega-frame at the full scrolled height.
- [ ] Component pages have one frame per component, not all components on one giant board.

Reference: https://developers.figma.com/docs/figma-mcp-server/avoid-large-frames/

### 7. Code Connect mappings (🟡 medium)

If the team uses Code Connect ([`code-connect.md`](code-connect.md)), the design-system components should already be mapped. Unmapped components mean the engineer sees raw shapes in Dev Mode instead of real Swift code.

- [ ] `get_code_connect_map(fileKey)` returns mappings for every design-system component (buttons, fields, cards).
- [ ] No stale mappings pointing at deleted SwiftUI types — these throw errors in Dev Mode.
- [ ] `get_code_connect_suggestions(fileKey)` returns < 5 suggestions (low = most things already mapped).

## The punch list format

When you return findings, group by the section above and lead with severity + the specific Figma node URL. Designers act on specifics, not generalities.

```
🔴 BLOCKING

[Components page → "ButtonPrimary - Default" (figma.com/...?node-id=…)]
  This is a Group, not a Component. Convert to a Component and add
  state/size variants so all 14 buttons across the file collapse to
  one source.

🟠 HIGH

[Settings page → frame "Profile section" (figma.com/...?node-id=…)]
  No Auto Layout. When the user picks Accessibility XXL Dynamic Type,
  the "Edit Profile" row will collide with the avatar. Switch to
  vertical Auto Layout with 16px gap.

🟡 MEDIUM

[Onboarding screens — entire page is one 4096×9000 frame]
  Fetch the relevant screen children separately if design context is truncated.
  Propose file restructuring only if the handoff task actually needs it.
```

## What you do NOT review

- **Visual design quality** — colour palette choices, type hierarchy, illustration style. That's the designer's craft, not your concern.
- **Brand decisions** — logo placement, marketing copy.
- **Whether the designer's mental model is "right"** — your job is to surface implementation friction, not redirect the design.

The audit is one-way: surface what's hard to implement, propose fixes that *preserve the designer's intent*. Never "you should redesign this."

## Self-review before sending the punch list

- [ ] Every item names a specific Figma node URL.
- [ ] Every item suggests a specific fix, not just "needs work."
- [ ] Grouped by severity (🔴 / 🟠 / 🟡) so the designer can triage.
- [ ] Total list ≤ 15 items — anything longer and the designer freezes. If there are more, ship the top 15 and offer a round 2.
- [ ] No visual-design critiques.

## References

- **Figma MCP — avoid large frames** → https://developers.figma.com/docs/figma-mcp-server/avoid-large-frames/
- **MCP tools and prompts** → https://developers.figma.com/docs/figma-mcp-server/tools-and-prompts/
- **Figma Auto Layout** → https://help.figma.com/hc/en-us/articles/360040451373
- **Figma Variables + modes** → https://help.figma.com/hc/en-us/articles/15145852043927
