# Simulator verification during code review

Use this reference for changed app behavior that benefits from runtime verification. The reviewer selects scenarios from the actual diff and requirements, performs or directs the checks, and assesses the evidence independently. This is a draft workflow; no app was tested while writing it.

## Keep the reviewed code fixed

Use `xcode-project-workflow`, `xcodebuild`, `apple-platform-testing`, and `screenshot` for their existing operations. Bind the run to the reviewed revision or frozen patch, actual build artifact, selected scheme/configuration/toolchain, exact Simulator UDID/runtime, and prepared fixture/state. Reuse a compatible build when possible.

The reviewer remains unable to change the reviewed source, project, index, or baseline. Grant only the test operations the current workflow supports, acquire the required build/device/GUI resources, and ensure builds cannot race with source changes. If a source change or new fixture implementation is needed, return it to the writer before reviewing the new revision. Do not bypass a denied capability by issuing equivalent shell commands. If a separate authorized runner must execute the scenario, distinguish that execution from the reviewer's assessment.

Use one destination and focused execution initially. Count internal test workers against the shared host limit. Preserve other tasks' Simulator state and release owned resources through the existing cleanup path. Do not erase devices, clear global caches, or add another coordinator for review.

## Choose edge cases from the logic

Trace the changed branch, state transition, event handler, or dependency boundary. Select the relevant critical flow and only the additional cases that could expose a material defect. These examples are candidates, not a required matrix:

| Changed logic | Useful scenario | Evidence for the claim |
| --- | --- | --- |
| Submission guard or action wiring | Tap twice before completion | Short recording plus an actual operation/result count when claiming one write |
| Async completion or cancellation | Leave the screen while work is pending, then return | Recording plus a focused result showing whether obsolete work affected state |
| Empty/error handling | Open the affected empty state, or trigger the handled failure and retry | State capture and observed retry outcome; label injected responses |
| Layout, keyboard, or typography | Relevant long text, large text, narrow width, or keyboard-visible state | Screenshot with alignment guides where useful, plus reachable-control observation |
| Storyboard or hybrid navigation | Open the real scene, use the changed action/segue, then return | Recording of the actual construction/navigation path and any relevant diagnostics |
| Gesture or animation state | Interrupt or reverse the changed interaction; check Reduce Motion when relevant | Trimmed recording of the trigger through the resulting state |

Prepare repeatable state using existing fixtures, launch arguments, or test seams. Avoid arbitrary sleeps; wait for observable conditions within a bound. If the current tools cannot trigger a timing window or inspect the needed state, report that limit and use a focused Swift test when appropriate. Do not build a mock-server or UI automation framework just to make a small review possible.

Prefer an existing stable XCUITest when it covers the scenario. Otherwise a reviewer-driven Simulator interaction is acceptable, with recorded steps and an explicit observed result. Add an automated regression only when its future value justifies maintaining it. Custom verification remains Swift.

## Connect proof to the code

For appearance, capture the relevant state. For interaction, record from just before the trigger through its outcome; keep the causal sequence intact. Use raw captures and a clearly labeled annotated/trimmed copy, inspect playback and boundary frames, and retain the source identity. Show a timestamp or marked region for the finding. Apple supports device captures for bug communication, accessibility review, and localization verification. [Apple capture guidance](https://developer.apple.com/documentation/xcode/capturing-screenshots-and-videos-from-devices).

Bind each artifact to its scenario and tested revision. Link the code permalink or changed symbol that explains the behavior, and cite an accepted requirement or specific official API reference when needed. Distinguish an observed failure from a suspected cause: a clip showing duplicate rows does not by itself establish which function wrote duplicate data. For hidden behavior, include a sanitized observed JSON result, log excerpt, or focused test result; identify fixtures and simulated responses.

When an existing XCTest produces the evidence, reuse its result bundle and attachments instead of creating duplicate reporting infrastructure. [Apple test attachments](https://developer.apple.com/documentation/xctest/adding-attachments-to-tests-activities-and-issues).

Keep the published report short:

```text
Scenario: <case and relevant input/state>
Build: <revision/artifact, Simulator and OS; detailed environment link if needed>
Steps: <short reproducible sequence>
Expected → Observed: <contract> → <actual result>; PASS / FAIL / BLOCKED / NOT RUN
Logic: <code permalink/symbol and its relation to the observation>
Proof: <screenshot or clip timestamp; supporting result when needed>
```

Publish findings and artifacts only within the current task's GitHub authorization. Include tested passes briefly in the summary; post review comments for actionable findings, not a comment for every passing case. Link longer reports from the concise PR body. A failed scenario gets the normal author assessment and fix loop, followed by the same scenario on the corrected revision.

Report environmental limits and untested cases without calling them passes. Simulator evidence does not establish physical-device performance or hardware behavior; use a device when the claim depends on those properties. [Apple Simulator/device guidance](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices).
