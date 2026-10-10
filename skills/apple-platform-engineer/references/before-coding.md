# Before coding

Run these five steps after intake and before the first production edit. Each
step names its owner; follow the owner for detail instead of restating it. A
[small change](../../agent-harness/references/small-change-path.md) runs steps
1, 4 and, when it renders UI, 5.

## 1. Working directory and branch rule

- Print the working directory, repository top level, current branch, working
  state and remote default branch. Confirm they are the authoritative checkout
  from `xcode-project-workflow`.
- Resolve the repository's branch rule from its instructions or the recorded
  project policy. When neither defines one, ask the user once, offer the
  [default branch model](../../git-workflow/references/branch-policy.md#default-branch-model),
  and record the answer in the project overlay so later tasks reuse it.
- Plan the PR split now. More than 20 changed source files means
  [stacked PRs](../../git-workflow/SKILL.md#plan-phase-sized-pull-requests).

## 2. Tests: edge cases first

Before writing a test, list the changed logic's edge cases, then write the
fewest meaningful tests that cover the ones that can change behavior.
`apple-platform-testing` owns
[test selection](../../apple-platform-testing/SKILL.md#choose-the-minimum-sufficient-evidence).

## 3. Current Apple guidance

For each framework the change touches (Swift, SwiftUI, UIKit, SwiftData,
Foundation Models and so on), read the selected Xcode's Apple-authored skills
or Documentation Search before choosing an API. Check the result against the
target's minimum OS. `xcode-project-workflow` owns
[Apple official-first routing](../../xcode-project-workflow/SKILL.md#apple-official-first-routing);
refresh a stale export only through `apple-platform-setup`.

## 4. Think before writing code

- Read the existing logic around the change and reuse its types, helpers,
  extensions and design-system components before adding new ones.
- Change only what the task needs. The stable branch works; do not refactor
  surrounding code, rename, reformat or move files the task does not require.
- Remove code the change makes unused, and do not add speculative parameters,
  protocols, flags or dead branches. Report other unused code you notice as a
  follow-up instead of deleting it in this change.
- Write no explanatory or commented-out code comments. Make names carry the
  meaning; when an API needs documentation, use a DocC `///` comment with
  `- Parameters:`, `- Returns:` and `- Throws:` as applicable.

## 5. UI against its design source

- With a Figma source, use `figma-bridge` for the draft and compare the
  integrated screen with the frame through `screenshot` or, for a repeatable
  report or snapshot test, `figma-golden-testing`.
- Without Figma, design and review the view in SwiftUI Previews through
  `xcode-preview-design`; preview UIKit through its `UIViewController` or
  `UIView` preview.
- Report each visual difference (spacing, color, typography, asset, state)
  with the fix or the reason it is accepted. A preview that compiles is not a
  visual match.
