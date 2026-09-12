---
name: trello-pm-card-sync
description: >-
  Turn rough Trello intake cards into agent-ready work units and keep their
  Figma, GitHub issue, PR, proof, QA, and TestFlight state synchronized. Use
  for PM card cleanup or Trello-to-GitHub issue tracking; do not use it to
  invent missing design decisions or claim QA without evidence.
---

# Trello PM card sync

Use the Trello card as the PM intake record and the GitHub issue as the
engineering work unit. Preserve each system's URL and ID, but keep the same
scope, acceptance criteria, and delivery state in both places.

## Discovery before editing

1. Read the card, its board/list, checklists, comments, labels, and visible
   links. Treat attached screenshots and free-form notes as evidence, not as a
   complete specification.
2. Find an existing GitHub issue in the confirmed personal repository. Match by
   card URL, feature wording, Figma node, or an explicit issue number. If there
   are multiple plausible issues, stop and ask which one is authoritative.
3. Record what is present and missing: node-specific Figma URL, route/source
   mapping, repro steps, expected behavior, issue URL, PR URL, commit SHA,
   test command/result, snapshot proof, and QA/TestFlight destination.
4. Do not call a card Done, QA-ready, or TestFlight-ready because a file is
   attached. Verify the observable result and its link.

If a visual card has no Figma link or the link is not node-specific, report the
card as blocked and ask the user/PM to provide the correct Figma URL. Do not
search for or choose a replacement frame silently; the user may supply the
authoritative link directly to the implementing agent.

## Title and body format

Rename vague image-based titles to:

`[Platform][Area] Verb + object + acceptance anchor`

Examples: `[iOS][UI] Set Timeline background to #ECECF2` and
`[iOS][UI] Match Timeline item Edit screen to Figma node 419-31291`.
When a design or behavior is missing, say so in the title or status instead of
guessing: `[iOS][UI] Define Photo Edit UI update (Figma required)`.

Write the body with the sections in [card-template.md](references/card-template.md):

- **Objective**: one testable sentence.
- **Context / route**: entry point, affected screen, and source symbol if known.
- **Design source**: node-specific Figma URL, frame size, and visible text for
  visual work. Mark `BLOCKED — Figma node required` when absent.
- **Scope**: concrete fields, colors, spacing, states, and exclusions.
- **Acceptance criteria**: observable Given/When/Then or numbered checks.
- **Verification fixture**: device/OS, locale, timezone, data, appearance, and
  deterministic interaction.
- **Proof required**: PR URL and commit, test command/result, raw screenshot,
  side-by-side, overlay, diff heatmap, metrics, and field-level text results
  when the change is visual. Link checked-in or PR-visible files.
- **Status and handoff**: Backlog, In Progress, In Review, Blocked, QA, or
  TestFlight, with the reason and owner. QA/TestFlight means the stated gates
  passed; it is not a synonym for “someone attached an image.”
- **Sync links**: Trello card URL, GitHub issue URL, PR URL, Figma URL, and
  proof URLs. Use `Not provided` or `Not applicable` explicitly.

## Figma and snapshot gates

For visual UI work, require a node-specific Figma URL and map it to the real
SwiftUI view or view controller. Capture the deterministic screen, inspect
visible text, and preserve the raw inputs. Use the repository's Figma golden
testing guidance for the Swift Testing/Point-Free SnapshotTesting command and
the comparator. Report pixel mismatch as `FAIL` with the percentage and the
fields that differ; a passing capture alone is not parity evidence.

## GitHub and Trello synchronization

- Create one GitHub issue per independently reviewable card when no match
  exists. Put the Trello URL in the issue body and the issue URL in the card.
- Update both records together when title, scope, acceptance, or status changes.
  Keep one writer for a card/issue pair and preserve unrelated comments.
- A PR link is required before `In Review`; a verified proof bundle is required
  before `QA` or `TestFlight`; a merged PR and accepted QA result are required
  before `Done`.
- If the board lacks a QA or TestFlight list, report that fact and create or use
  a destination only when the user requests the workflow. Move only cards that
  meet the destination's gates, and list cards that remain blocked.

## Failure handling

Keep the last failed test result and proof links in the card and issue. Retry a
failed snapshot after fixing the narrowest cause. Stop when the Figma node,
deterministic fixture, or required simulator/toolchain is unavailable, and name
the missing input rather than fabricating parity.
