# The comment-as-sitemap convention

The cheapest, most durable link between a code file and a Figma frame is a one-line comment at the top of the file. No tooling, no plugin, no database — just a URL that points back to the design.

The whole convention:

```swift
// figma: https://www.figma.com/design/AbCdEf/MyApp?node-id=42-7
//
// ProfileView — the screen the user lands on when they tap their avatar.
// Designer: Anna · last design review: 2026-04-12
```

That's it. The next engineer (or agent) reads the file, clicks the URL, lands on the exact frame. The next designer can grep the codebase for the Figma file ID and see every file that implements something from it.

## Why this beats fancier alternatives

Code Connect (the formal Figma mechanism) only maps **components** — buttons, badges, toggles. It doesn't naturally map *screens* (which compose many components). And it requires CI to keep mappings fresh.

A `// figma:` comment maps **anything** — components, screens, partial flows, sub-views. It costs zero. It survives renames (only the URL needs updating if the node moves; the file path is irrelevant). It's greppable. It shows up in code review automatically.

You can — and probably should — use both. Code Connect for the design-system primitives, comment-sitemap for screens and one-off views.

## Where to put the comment

| Kind of file | Where the comment goes |
|---|---|
| Screen / page-level `View` | Top of the file, above `import` |
| Reusable component (`Button`, `Card`, `Badge`) | Top of the file. Also consider Code Connect for these. |
| UseCase / ViewModel | Skip — these aren't UI, no Figma mapping |
| Section / sub-view inside a larger file | Inline comment above the `struct` declaration |

```swift
// figma: https://www.figma.com/design/AbCdEf/MyApp?node-id=42-7
import SwiftUI

struct ProfileView: View { … }

// figma: https://www.figma.com/design/AbCdEf/MyApp?node-id=42-19
private struct ProfileHeaderRow: View { … }
```

## What the URL should point to

- A **named frame**, not a free-floating layer. Frames have stable names; layers get renamed constantly.
- The **smallest meaningful node** — if the file is `ProfileHeaderRow.swift`, link to the `ProfileHeaderRow` component, not the whole `ProfileView` page.
- Use the canonical Figma URL form (`https://www.figma.com/design/<fileKey>/<fileName>?node-id=<nodeId>`). Avoid the legacy `figma://` deep-link form — modern Figma serves both, the HTTPS form is what's clickable in every editor.

## Updating the comment when the design moves

When the designer renames or moves the source frame, the URL still works (Figma keeps redirects for renamed nodes) but the *node-id* may change. The easy fix:

1. Open the file. Find the `// figma:` line.
2. Cmd-click the URL. It opens in Figma. If Figma can resolve it (even via redirect), copy the *current* URL from the address bar and paste back over the old one.
3. If Figma can't resolve it, the node was deleted. Ask the designer what replaced it, update the comment, or remove the comment if the file's design intent has moved on.

## A simple grep workflow

```bash
# Find every file with a Figma mapping
rg '^// figma:' --type swift

# Find every file that maps to a specific Figma file
rg "figma\.com/design/AbCdEf" --type swift

# Find files WITHOUT a Figma mapping that probably should have one
# (heuristic: a SwiftUI screen-level View struct in a top-level Views/ dir)
fd -e swift Views | while read f; do
    rg -q '^// figma:' "$f" || echo "missing: $f"
done
```

The third command is the developer-friendliness check the engineer can run before handoff back to the designer — "here are screens with no design link, do they exist in the Figma file?"

## When you generate a file from a Figma frame

The agent must add the `// figma:` comment to every file it writes from `generate_figma_design`. The URL is the exact node you generated from. No exceptions.

If the agent is editing an existing file and notices the comment is missing, **suggest adding it** (don't add silently — the engineer may have deliberately omitted it for an internal-only utility).

## Self-review

- [ ] Every screen-level View file has a `// figma:` comment with a valid URL.
- [ ] Reusable components either have a `// figma:` comment OR a Code Connect mapping (often both — see [`code-connect.md`](code-connect.md)).
- [ ] No `// figma:` URL points at a deleted node (the URL would 404 or land on a "page not found" Figma view).
- [ ] The comment is at the top of the file, above `import`, so it's the first thing reviewers see.

## What this is NOT

- Not a replacement for Code Connect. They serve different purposes — Code Connect maps *components* for designer-facing Dev Mode; the sitemap maps *files* for engineer-facing navigation.
- Not a design spec. The comment links to the design; it doesn't describe the design. Don't paste prose ("blue button, 16pt corner radius") — that's what the Figma file is for.
- Not a project-management tool. Don't add ticket numbers, sprint labels, status fields. The line stays short and stable.
