---
name: release-qa-handoff
description: >-
  Hands a processed Xcode Cloud or uploaded TestFlight build to QA: correlates the build with the merged pull requests it contains and the tracker cards those close, records the exact version/build and what changed on each card, moves cards to the configured QA list, and drafts a short What to Test note for approval. Use after a merge reaches a tester-accessible build, or when asked to move cards to QA, stamp a build number onto cards, or write TestFlight release notes for testers. Do not use to upload, distribute or submit; those stay with app-store-connect.
---

You connect three things that already have owners but no one joins: a **build**,
the **merged work inside it**, and the **tracker cards** that work closes.

Everything you write is read by a tester deciding what to exercise. Prefer a
short, concrete sentence about observable behavior over a commit summary.

## What you own, and what you do not

| Step | Owner |
|---|---|
| Build processing state, tester access, distribution, release-note publication | `app-store-connect` (`asc-build-lifecycle`, `asc-testflight-orchestration`) |
| Card text conventions, English authoring, title format, board audit | `trello-pm-card-sync` |
| Xcode Cloud workflow configuration and CI failures | `cicd` |
| Correlating build ⇄ merged PRs ⇄ cards, stamping cards, moving them to QA, drafting the tester note | **you** |

Never upload, distribute, submit, or change a workflow yourself. When a step
belongs to another skill, name it and hand over the resolved facts.

## Resolve the build before touching anything

Read the build identity from App Store Connect or Xcode Cloud, never from the
local project, a tag, a PR or an older release. Record marketing version, build
number, the commit it was built from, and its processing state.

Three conditions gate everything below. State which are met:

1. The build finished processing.
2. It contains the intended commit.
3. It is available to the intended tester or group.

If any is unmet, stop before the QA move: update the card description with what
is known, keep the readiness status at `Not Ready` with the reason, and say what
is missing. A processed build is not tester access, and neither is a passing
merge. An unconfirmed number stays `Build TBD` rather than a guess.

## Correlate the build with the work inside it

Take the commit range between this build's commit and the previous build's, then
resolve the merged pull requests in that range. For each PR, read its title and
body for the tracker card it closes — a card link, a closing keyword, or the
card number in the branch name. Keep the card's own title as the tester-facing
phrasing; it is already written for a reader, while a commit subject is written
for a reviewer.

Report what you could not correlate rather than dropping it: a PR with no card,
a card with no PR in this build, or a commit that reached the build without a
pull request. Those are the cases where a QA move would be wrong.

## Update the cards (no confirmation needed)

For each correlated card, keep the existing description and append or refresh a
single block. Preserve the original content, the historical results and the
checklist state — you are adding release facts, not rewriting the card.

```text
**In build**
TestFlight <marketing version> (<build>) — processed <date>, available to <group>.
Source: <commit> via <PR links>

**What changed**
<one sentence, observable behavior, from the PR title/body and the card title>

**How to check**
<the card's own acceptance step, or the reproduction it was filed with>
```

Then move the card to the configured QA list and set the title's readiness
status to `Ready for Testing`, following `trello-pm-card-sync` for the title
format. Ready for Testing means QA can start; it never means QA passed, and you
never mark a card done on its behalf.

Do not create lists, labels or fields to express this. If the configured QA list
is unknown, ask once and continue preparing the rest.

## Draft the What to Test note (approval required)

The note is external content that reaches testers, so you draft it and wait for
an explicit approval before it is published — and `asc-testflight-orchestration`
publishes it, not you. Show the exact text you propose.

Keep it to what a tester does:

```text
<marketing version> (<build>)

Fixed
- <observable change>, check <where>
- <observable change>, check <where>

Please try
- <the flow most likely to regress, in one line>
```

Write for someone who has not read the PRs. Name the screen and the action, not
the type or the file. Leave out refactors, dependency bumps and anything with no
visible effect; a tester cannot act on them. If a fix needs a specific starting
state — an upgrade from an older install, an existing item, a particular region —
say so, because otherwise it will not be exercised.

Do not translate the note unless asked; follow the board's configured language
for card text and the app's tester audience for the note.

## Report

Say separately: which cards were updated and moved, which were left behind and
why, what the note says, and whether it is still awaiting approval. A card moved
to QA and a build a tester can actually install are different facts — keep them
distinct, and never imply testing has started or passed.
