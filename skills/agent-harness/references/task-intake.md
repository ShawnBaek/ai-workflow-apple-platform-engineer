# Clarify what the user wants to build

Start an assigned task by establishing the intended outcome before choosing architecture, delegating implementation, or splitting PRs. The lead and direct specialist entry points share this check. A small task needs only a brief understanding statement; it does not require the full harness or a separate specification document.

## Establish the outcome from available context

Read the current request, relevant prior answers, accepted requirements, and the affected project context. State the intended result in the user's terms. Separate what the user requested from an implementation idea suggested by the agent.

Resolve the following only to the depth the task needs:

- **Purpose and user:** who uses the feature, what they are trying to do, and the problem it should solve.
- **Expected behavior:** the important flow, input/output, and states or edge cases that change the experience.
- **Scope and deliverable:** what this task should produce, such as a preview, working feature, local fix, or authorized PR; avoid silently adding adjacent features.
- **Constraints:** relevant platform/minimum OS, existing SwiftUI/UIKit/storyboard approach, data/privacy boundary, compatibility, and meaningful performance requirements.
- **Design source and acceptance:** the applicable Figma/reference or code-first preview, and observable evidence that will show the result meets the request.
- **Competitors and preferred style:** for new UX/UI, an app website, an icon concept or a substantial visual/interaction redesign, ask about references and style when they would change the result. Follow [design discovery](design-discovery.md) for targeted research and a shared direction; reuse supplied answers and skip this for precise fixes or an already approved design.

Use known project facts and previous user answers. Existing code explains current behavior; it does not by itself establish what the user wants changed.

## Ask only questions that affect the result

When multiple plausible interpretations would produce meaningfully different features, ask concise targeted questions early. Usually one to three questions are enough; suggest clear options when helpful. Ask about outcomes and constraints before asking the user to select an implementation pattern.

Reuse information already provided. For a precise request, briefly state the understanding and proceed. For a reversible implementation detail, make a reasonable choice and identify a material assumption. Do not silently guess an unresolved core behavior, data boundary, or acceptance criterion.

When asynchronous clarification is available, continue independent work such as source inspection or reference research. Keep implementation that depends on a required answer pending. Silence does not settle a required question or grant approval. An explicit answer already supplied is sufficient; do not request another confirmation for the same decision.

For UI work where prose leaves the desired experience unclear, use a small SwiftUI/UIKit preview with fixed values to make the choice concrete when useful. Validate the direction before adding dependent domain logic. Avoid building several complete alternatives merely to ask a design question.

## Carry a compact task brief forward

Capture the result in the existing task/plan, scaled to its size:

> Build/change <behavior> for <user or workflow> so that <outcome>.
> Scope: <affected flow and relevant limits>. Constraints: <known requirements>.
> Done when: <observable acceptance criteria and suitable evidence>.
> Open questions/assumptions: <only unresolved material items; omit when none>.

Distinguish explicit requirements, confirmed answers, and agent assumptions. For broad work, make the intended first deliverable and meaningful exclusions clear. Routine fixes can fit in one sentence. Do not turn the brief into mandatory paperwork or repeat it in every progress update.

Then inspect relevant ADRs and create a new decision record only when justified. Break implementation into coherent tasks/PRs using the clarified acceptance criteria. Use graph structure only when actual dependencies justify it.

Give delegated workers the same brief, applicable decision references, and their bounded assignment. Workers must not invent competing product requirements. When the user clarifies or changes the request, update the affected criteria and assignments; revisit only the dependent architecture, implementation, and checks.

Completion and review must assess the clarified user outcome as well as technical correctness. A successful build, attractive screenshot, or plausible model response alone cannot establish that the requested feature was built.
