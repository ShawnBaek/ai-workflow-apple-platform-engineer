# Before coding

Run these five steps after intake and before the first production edit. Each
step links its owner; follow the owner for detail. A
[small change](../../agent-harness/references/small-change-path.md) records
only the working directory and checkout state in step 1, skips the PR split,
and uses its one render in step 5.

## 1. Working directory and branch rule

- Record the working directory and the authoritative checkout from
  `xcode-project-workflow`.
- Resolve the branch rule and intended base through the
  [default branch model](../../git-workflow/references/branch-policy.md#default-branch-model).
- Plan the PR split against the
  [stacked-PR limit](../../git-workflow/SKILL.md#plan-phase-sized-pull-requests).

## 2. Edge cases before tests

Follow [test selection](../../apple-platform-testing/SKILL.md#choose-the-minimum-sufficient-evidence).

## 3. Current Apple guidance

Follow [Apple official-first routing](../../xcode-project-workflow/SKILL.md#apple-official-first-routing)
for each framework the change touches.

## 4. Think before writing code

- Read the existing logic around the change and reuse its types, helpers and
  components; the small-change path's reuse rule applies to every change.
- Change only what the task needs. The stable branch works; do not refactor,
  rename, reformat or move code the task does not require.
- Remove code the change makes unused, and add no speculative parameters,
  protocols, flags or branches. Report other unused code as a follow-up.
- Write no explanatory or commented-out code. Let names carry the meaning; when
  an API needs documentation, use a DocC `///` comment with `- Parameters:`,
  `- Returns:` and `- Throws:` as applicable.

## 5. UI against its design source

Follow the lead's [UI path](../SKILL.md#ui-path).
