# Check architecture decisions at task intake

The harness owns this check. The lead first establishes the user's intended outcome through [task intake](task-intake.md), then checks architecture decisions before breaking work into implementation tasks. Specialists use the resulting constraints. No separate ADR skill or agent is needed.

## Read, classify, then plan

1. Find the repository's existing decision log and template. Read only decisions relevant to the affected feature, platform, data boundary, or shared resource. Prefer the established location; if a new log is needed, `docs/adr/` is a reasonable default.
2. Check status, scope, and superseding records. Separate the accepted decision from the implementation's current behavior. A conflict with the task or current SDK needs investigation, not silent precedence by whichever document is newest.
3. Decide whether the task follows an existing decision, introduces a significant new choice, or needs to supersede a decision. For ordinary work, a brief note in the existing plan is enough; do not generate an empty ADR or a new tracking artifact.
4. When needed, draft a short ADR during planning, before dependent implementation is committed to that direction. A bounded preview, research task, or experiment may provide missing decision evidence first.
5. Carry the relevant decision ID/status into affected task assignments and review context. Reassess if implementation reveals a material tradeoff the original decision did not cover.

## When a new ADR helps

| Significant choice | Example |
| --- | --- |
| Supported platform or runtime strategy | Minimum OS change; optional Foundation Models path and its fallback |
| Data ownership or external boundary | Persistence/sync approach; on-device versus server processing of user content |
| Long-lived dependency or interface | A new model runtime, package, shared service contract, or module boundary |
| Cross-cutting resource or reliability policy | Simulator ownership, host capacity admission, model/session lifetime, or cache retention |
| Construction strategy with lasting consequences | A deliberate storyboard-to-SwiftUI migration or hybrid ownership boundary |

A color adjustment, local bug fix, routine test, compatible API substitution, or screen following an established pattern normally needs no new ADR. A performance optimization needs one only if it changes a significant contract or creates a lasting tradeoff. A task split is a plan, not itself an architecture decision.

Use the existing template, or the [compact fallback](../templates/adr.md). Record the context, actual alternatives, chosen direction and reason, consequences, and supporting references. Include minimum OS/SDK and validation evidence only where relevant. Do not invent alternatives or add speculative layers to make a decision look architectural.

## Keep authority and ownership clear

Use the repository's lifecycle. Where none exists, use `proposed`, `accepted`, `rejected`, and `superseded`. Drafting an ADR does not accept it. Record the decision owner and the actual authority for acceptance. An explicit user decision or existing delegated authority can already settle the choice; do not request the same approval again. A material unresolved product or architecture decision goes to its owner while independent work continues.

Keep accepted rationale intact. Replace a changed decision through a linked superseding ADR, retaining why the earlier choice made sense. Rejection should retain its reason when it is useful to future work. This follows the decision/context/consequence and lifecycle approach in [AWS ADR guidance](https://docs.aws.amazon.com/prescriptive-guidance/latest/architectural-decision-records/adr-process.html); the task-size policy here is specific to this collection.

For concurrent tasks, one owner maintains the shared decision under existing repository-write coordination. Workers contribute evidence or alternatives and receive the same decision version. A conflicting proposal must be resolved before affected implementations diverge; no agent may silently promote its preference to an accepted project rule.

## Connect the decision to delivery

Link the ADR from the affected plan and PR rather than copying its full text. Keep it in the first coherent implementation PR when that is easiest to review; use a separate decision PR only when agreement is needed before several dependent changes. Publication and commits still require their existing approvals.

The reviewer checks the decision's applicability, cited evidence, alternatives/tradeoffs, and implementation consistency. A concern should cite the relevant ADR and code; an accepted ADR can still need revision when new evidence invalidates its assumptions. Verify its important consequences through focused checks, never by merely checking that an ADR file exists.
