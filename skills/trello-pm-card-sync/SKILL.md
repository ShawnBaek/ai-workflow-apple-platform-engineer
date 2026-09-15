---
name: trello-pm-card-sync
description: >-
  Turn rough Trello intake cards into reusable agent-ready work units, and,
  when explicitly requested, synchronize confirmed delivery state with the
  configured tracker. Use for card cleanup, handoff, or opt-in tracker sync.
---

# Trello PM card sync

Use this skill in four distinct modes. **Audit** is read-only discovery.
**Normalize** improves a card as a self-contained PM handoff without
implementing, running tests, or changing another tracker. **Sync** is an
explicit, idempotent cross-tracker update. **Handoff** supplies the next owner
with a bounded work unit and evidence requirements. A card can stop after any
mode.

Before acting, confirm the configured board/list, title convention, design
source requirement, status vocabulary, and source-of-truth mapping. These may
come from the user, board policy, or repository workflow. Do not assume a
particular organization, personal owner, repository, list name, or companion
tracker.

## English and board-visible QA status

- Write all agent-authored Trello titles, descriptions, checklist names/items,
  comments, and status text in English, even when the conversation is in Korean.
  Preserve identifiers, URLs, and quoted original evidence. When translation is
  requested, translate existing authored content without dropping requirements,
  unresolved questions, historical results, or changing checklist completion.
- For TestFlight QA cards, put the readiness status, marketing version, and
  build number in the title so they are visible without opening the card:
  `[Ready for Testing] [TestFlight 1.2.3 (456)] Verify <outcome>`.
  Repeat the exact version/build and source revision in the description.
- Use `Ready for Testing` only after the matching build is processed, includes
  the intended revision, and is available to the intended tester/group. Until
  then, use `Not Ready` in the title and explain the reason in the description
  (for example, not uploaded, processing, access pending, or unconfirmed build).
  Use `Build TBD` for an unconfirmed number. Never infer a TestFlight
  build number from the local project, PR, or an older release. Ask for a missing
  build identity while continuing independent card preparation.
- Reuse existing board labels or visible custom fields when supported; always
  retain version/build/status in the title. Do not change lists or create new
  labels/fields merely to format a card. Testing readiness is not a QA pass.
- When a processed build already contains the merged work, stamping its
  version/build onto the cards, moving them to the QA list and drafting the
  tester note belongs to `release-qa-handoff`; it resolves the build identity
  and returns here for the card text conventions above.
- Avoid accidental headings: never start a prose line with a ticket marker
  such as `#111`; use `Tickets: #111, #114` or a bullet. Keep result paragraphs
  short and use descriptive links such as `[PR #123](https://example.com/pr/123)`.
  Verify saved text and rendered formatting when the UI is available.

## Target version for app Todo cards

Before creating or normalizing a Todo card for an App Store app, verify the
app's currently released App Store marketing version from live App Store or
App Store Connect evidence. Confirm the app identity, such as its product page,
bundle ID, or App Store ID, so a similarly named app or stale local project
version is not treated as the current release.

Use the requested scope to recommend the next target marketing version:

- Recommend a patch increment for fixes and small maintenance changes.
- Recommend a minor increment for a new user-facing capability.
- Recommend a major increment only for an explicitly breaking or fundamental
  product change.

Tell the user the verified current version and the recommended next version,
then ask them to confirm the target version. Do not create or normalize the
Todo card, or attach its target-version label, until the user explicitly
confirms. After confirmation, apply the board's established target-version
label or visible custom-field convention and read the card back to verify it.
If the board has no named version label/convention, or the required label does
not exist, report that and ask how to proceed instead of guessing, reusing an
unnamed label, or creating a new label without authorization.

## Audit

Read the card, board/list, checklists, comments, labels, attachments, and
visible links. Preserve their text, attachment URLs, authorship, and timestamps
as PM evidence. Record confirmed and missing objective, route/source mapping,
design source, acceptance criteria, linked work item, delivery links,
verification evidence, and status.

If more than one linked work item is plausible, report the ambiguity and ask
which is authoritative. Audit does not rename, move, create, or update records,
and it does not execute implementation or verification commands.

## Normalize

Only after a requested normalization, improve the title and add a clearly
separated agent-ready brief using [card-template.md](references/card-template.md).
Keep the original PM description, comments, checklists, attachments, and links
intact; do not replace them with inferred requirements. Follow a configured
title convention. If none exists, use a concise outcome-oriented title such as
`[Platform][Area] Verb + object`.

Mark unknown fields `Not provided` and unresolved requirements `Blocked`.
Normalization prepares work only: it must not implement code, run tests, capture
screenshots, claim QA/TestFlight results, create a branch/PR/issue, or move a
status based on an assumption.

Require a node-specific Figma URL only when the configured task or acceptance
criteria requires a Figma-backed visual result. If a required source is missing
or not node-specific, mark `BLOCKED — required design source missing` and ask
the user/PM for the authoritative URL. Never select or guess a replacement
frame. For non-visual work, or work whose configured design source is code, a
prototype, or `Not applicable`, state that source explicitly.

## Sync

Sync is opt-in: obtain the requested direction, systems, fields, and
source-of-truth mapping before the first external write. A mapping may make
Trello own scope/acceptance criteria and a configured issue tracker own
branch/PR or delivery status. Do not overwrite fields owned elsewhere, original
PM content, or attachments.

1. Re-read both records and compare configured fields, URLs, and IDs.
2. If owned fields conflict, stop and report both values and sources; ask for
   resolution rather than choosing one.
3. Apply only minimal requested changes, with stable cross-links and an
   operation key or equivalent idempotency marker when supported.
4. Read both records back. If the requested state already exists, record a
   no-op rather than creating a duplicate item, comment, or link.
5. On partial success, preserve the completed record, report the exact failed
   operation and current readback, and retry only an unambiguous idempotent
   operation when authorized.

Use the configured status mapping. If none exists, keep the current status and
report that a mapping is needed; do not create lists, fields, or options as a
workaround.

## Handoff and evidence gates

The handoff identifies the next owner, scope, exclusions, acceptance criteria,
required design source, verification fixture, links, and known blockers. A card
becomes ready only when its configured readiness conditions are evidenced; a
link or attachment alone is not proof.

For QA, require evidence appropriate to changed behavior, such as a test
result, observed device/simulator behavior, and visual comparison where visual
acceptance is required. For TestFlight, require a real uploaded/processed build
containing the intended revision plus evidence that the requested tester or
group has access. A PR, merge, archive, or screenshot alone establishes neither
condition. Preserve failed evidence and state the blocker instead of promoting
the card.
