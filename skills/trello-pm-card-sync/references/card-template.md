# Agent-ready card template

Copy this structure into a Trello card and the matching GitHub issue. Replace
every placeholder; leave `Not provided` when the PM must supply information.

```markdown
## Objective
[One testable sentence]

## Context / route
- Platform: iOS
- Entry point: [screen → action → screen]
- Source mapping: [SwiftUI view / view controller / file, or Not provided]

## Design source
- Figma: [node-specific URL or BLOCKED — Figma node required]
- Frame: [name, width × height]
- Visible text/states: [labels, buttons, text views, empty/loading/error states]

If the Figma URL is missing, keep the card `Blocked` and ask the user/PM for
the authoritative node URL before implementation or visual QA.

## Scope
- [Concrete change]
- [Concrete change]
- Exclusions: [what must remain unchanged]

## Acceptance criteria
- Given [fixture], when [action], then [observable result].
- [Layout/color/typography or behavior check]
- No regression in [related route/state]

## Verification fixture
- Device / OS: [exact simulator or device]
- Locale / timezone / appearance: [values]
- Data: [stable sample values]
- Command: [exact Swift Testing/XCTest command]

## Proof required
- PR: [URL and commit SHA]
- Test result: [PASS or FAIL, command, xcresult/log link]
- Visual proof: [raw screenshot, side-by-side, overlay, diff heatmap]
- Metrics: [metrics JSON/SVG and match percentage]
- Text results: [field-level JSON/SVG]
- Failure message: `Pixel comparison: [PASS/FAIL] — [percentage]% matching; mismatches: [fields].`

## Status and handoff
- Status: [Backlog / In Progress / In Review / Blocked / QA / TestFlight / Done]
- Blocker: [reason or None]
- QA/TestFlight destination: [list/card URL or Not available]

## Sync links
- Trello: [card URL]
- GitHub issue: [issue URL]
- Figma: [URL]
- PR: [URL or Not provided]
- Proof: [URLs]
```

For non-visual work, keep the same sections but set Design source to
`Not applicable` and replace visual proof with the smallest behavior-specific
evidence. Do not mark a card `Done` until the proof links resolve and the
acceptance criteria have an observable result.
