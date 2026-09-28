# Small-change path

Task intake decides whether a change is small. The lead and each specialist
that links this page then follow this path, which keeps each gate that protects
the app and drops the stages only a larger change needs.

## What counts as small

All of these hold:

- **Contained:** presentation-only, such as a style, color, spacing, copy or
  symbol edit, or an equally contained change.
- **No new behavior:** no new API, data, navigation, concurrency or persistence
  behavior.
- **Reversible:** reverting the patch restores the previous state; no migration,
  stored data or published contract depends on it.
- **Narrow:** one screen, or one component with few call sites that one
  Preview render represents. Search the call sites before deciding.
- **Not expanded:** the person has not asked for more, such as a design pass,
  new tests, more platforms or a device matrix.

Restyling the sign-in screen's button is small. Restyling a design-system button
style that about forty screens use on iPhone and iPad is not.

## Path

1. State the task in one sentence with the assumption that makes it small, and
   proceed; ask only about a material ambiguity ([task intake](task-intake.md)).
   Work in the current session with the owning specialist, such as
   `apple-platform-ui`, plus the gates it links (format and compile, build).
2. Keep the safety and approval gates: `xcode-project-workflow`'s project gate
   and Xcode selection, `git-workflow`'s checkout and pre-existing-change rules,
   and the [standalone ownership check](project-customization.md#standalone-ownership-check)
   before a build.
3. Reuse the existing component, style or asset. Do not add a near-duplicate or
   hardcode a value that an asset or style already owns.
4. Edit in one pass.
5. Pass [Swift format and compile acceptance](../../apple-platform-testing/SKILL.md#swift-format-and-compile-acceptance)
   and [build and warning acceptance](../../apple-platform-testing/SKILL.md#build-and-warning-acceptance)
   for the affected app target, with no task-introduced warning.
6. Render the affected `#Preview` once, adding one only when none exists. When a
   Preview is impractical, capture one screenshot of the changed state. This
   replaces the critical flow and the Preview matrix. If neither can run, report
   the visual check as unverified.
7. Self-check against only the checklist items the diff touches.
8. Before a PR, get one focused round of independent review with one lens;
   its [verdict loop](../../code-review/SKILL.md#verdict-and-approval-loop)
   takes a second round only after a blocking finding. A local-only change
   needs no review unless the person or project policy asks for one.
9. Hand off in a few lines: checks and results, the render or screenshot,
   omitted checks and residual risk. A PR still follows `git-workflow`, and a
   screenshot published as PR media follows `screenshot`.

Skip design discovery, a Preview matrix, a specification, a plan or graph, a new
ADR, new tests (a fixed visual defect still gets the regression test
`apple-platform-testing` calls for), agents beyond the step 8 reviewer, Simulator
flows, the completion-report JSON, and the guarded runtime unless the project or
an active run requires it.

## Escalate

Return to the standard path, the entry skill's full flow, as soon as one of
these holds, and say so in one line that names the trigger:

- the style or component is shared widely: its call sites span screens that
  one render cannot represent, such as a design-system style many screens use;
- the change alters behavior, accessibility semantics (label, traits, focus
  order), Dynamic Type or Increase Contrast behavior, or layout across size
  classes, or it lowers text or control contrast;
- the person asks for more;
- a check still fails after one evidence-driven correction.

Work and evidence already gathered carry over; add only the checks the trigger
requires.
