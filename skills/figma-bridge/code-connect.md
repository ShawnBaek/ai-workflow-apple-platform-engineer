# Code Connect for SwiftUI

Code Connect is the durable link between a Figma component and the real SwiftUI type that implements it. Once wired, Figma's Dev Mode shows the engineer's actual code next to the design — no copy-pasting, no drift.

## Two install routes (pick one per repo)

Figma documents both; they don't co-exist well in the same repo. Pick the one that fits the team's workflow:

| Route | Install | Best for |
|-------|---------|----------|
| **CLI** (per-developer) | `figma connect` Swift package; each engineer runs `figma connect publish` after editing mappings | Solo / small teams, repos already comfortable with CLI tooling |
| **GitHub plugin UI** (per-repo) | Install the Figma app on the GitHub repo; designers + engineers manage mappings from inside Figma | Teams where designers want to see / edit mappings without touching code |

Comparison reference: https://developers.figma.com/docs/code-connect/comparing-cc/

## Route A — CLI (Swift package)

Setup once per repo:

```bash
# Add the Swift package dependency in Package.swift:
#   .package(url: "https://github.com/figma/code-connect", from: "1.0.0")
# Then in your Package.swift target deps: .product(name: "Figma", package: "code-connect")

# Initialize the CLI config
swift run figma init
# Creates ./figma.config.json
```

`figma.config.json` declares where to scan for `.figma.swift` mapping files and what your design tokens are.

Write one `.figma.swift` file per mapped component:

```swift
import Figma

struct ButtonStyleConnect_PrimaryFilled {
    @FigmaConnect("https://figma.com/design/<fileKey>/<file>?node-id=12:34", example: {
        Button("Save", action: {})
            .buttonStyle(.primaryFilled)
    })
    init() {}
}
```

Publish so designers see the snippet in Dev Mode:

```bash
swift run figma publish
```

CI: run `swift run figma validate` on every PR — catches stale mappings whose Figma node was deleted or renamed. Add to `.github/workflows/build-and-test.yml` (the `cicd` skill's workflow templates have a slot for it).

## Route B — GitHub plugin UI

Install the Figma app on the GitHub repo (https://github.com/marketplace/figma). Once installed:

- Designers can browse to a component in Figma → "Connect to code" → pick a file from the repo → done. No engineer in the loop.
- The mapping lives in `.codeconnect/` JSON files in the repo, committed by the Figma GitHub app as a PR you review.

Reference: https://developers.figma.com/docs/code-connect/code-connect-ui-github/

**When this route shines:** designers can iterate the mapping without filing tickets. The engineer reviews the PR (small JSON diff) and merges.

**When CLI wins:** you want the mapping code-reviewed alongside the real SwiftUI changes in the same PR. CLI files live next to the component they describe.

## SwiftUI-specific patterns

Reference: https://developers.figma.com/docs/code-connect/swiftui/

### Modifier-style components

```swift
@FigmaConnect("https://figma.com/...?node-id=42:7", example: {
    Text("Hello").font(.headline)
})
struct HeadlineTextConnect {}
```

### Components with variants → property-based switching

```swift
@FigmaConnect("https://figma.com/...?node-id=42:8", example: { variant in
    switch variant {
    case .primary:   PrimaryButton(title: "Save", action: {})
    case .secondary: SecondaryButton(title: "Save", action: {})
    case .destructive: DestructiveButton(title: "Delete", action: {})
    }
})
struct AppButtonConnect {
    enum Variant: String { case primary, secondary, destructive }
}
```

### Components with bindings → use mock state

```swift
@FigmaConnect("https://figma.com/...?node-id=42:9", example: {
    StatefulPreviewWrapper("") { binding in
        SearchField(text: binding, placeholder: "Search…")
    }
})
struct SearchFieldConnect {}
```

(`StatefulPreviewWrapper` is a tiny helper many SwiftUI repos already have — it gives a `@Binding` to a preview block. If the repo doesn't have one, add it once to a `PreviewHelpers.swift`.)

## Bidirectional with the MCP server

If the Figma MCP server is connected, you can:

- Read existing mappings: `get_code_connect_map(fileKey)`
- Add a mapping from inside the editor: `add_code_connect_map(...)`. Behaves the same as the CLI publish — pushes to Figma immediately.
- Pull suggestions: `get_code_connect_suggestions(fileKey)` — Figma scans for unmapped components that *look like* a known SwiftUI type and proposes the mapping.

Reference: https://developers.figma.com/docs/figma-mcp-server/tools-and-prompts/

## Self-review before publishing a mapping

- [ ] The `example:` block compiles. (CLI: `swift run figma validate` catches this. UI: review the SwiftUI file from the agent.)
- [ ] The example uses *the real component*, not a stripped-down version. Designers will copy it.
- [ ] Variants in Figma match the enum cases in the example. If Figma has a `state` variant the SwiftUI doesn't, fix the SwiftUI or drop the variant from Figma.
- [ ] The Figma URL is the *current* node — not a snapshot from before the component was moved.
- [ ] No secrets / API keys in the example block (it's published to Figma — visible to anyone with file access).

## References

- **Quickstart** → https://developers.figma.com/docs/code-connect/quickstart-guide/
- **SwiftUI** → https://developers.figma.com/docs/code-connect/swiftui/
- **GitHub UI route** → https://developers.figma.com/docs/code-connect/code-connect-ui-github/
- **Comparing the routes** → https://developers.figma.com/docs/code-connect/comparing-cc/
- **Source: figma/code-connect (Swift)** → https://github.com/figma/code-connect
