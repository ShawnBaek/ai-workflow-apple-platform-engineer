# Design discovery intake walkthrough

Scope: shared competitor/style intake and its UI, Preview, Figma, website and
icon entry points. This is a documentation-only follow-up to the repository
rename/README patch based on `0d033bbb68d22e8cbf178cbb34853a58675ab7bb`.

## Method and inputs

Read-only Codex subagent walkthroughs on 2026-09-05 used GPT-5.6 Luna at medium
reasoning. Each attempt started with fresh context and the candidate skill
paths. Agents received raw requests and fixtures, not the evaluation rubric or
earlier reports. They selected relevant references from the named skill.
Source review was performed independently. No existing-release baseline was run
for this new behavior; the failures below occurred during candidate development.

1. **Missing direction:** “Design a new family-budgeting onboarding screen in
   SwiftUI for iOS 18. Help household members understand shared spending.”
2. **Supplied brief:** NoteNest saved-items screen; study a supplied fictional
   FlashList product-page snapshot. The snapshot shows per-row Save, Undo,
   newest-first items, optional detail tags and a required first-save collection
   choice, with gradients and a bouncing badge. The user likes quick Save/Undo,
   dislikes the collection gate and wants existing teal, calm native style and
   low motion. The snapshot contains no loading/offline/error/accessibility or
   timing evidence. Request a brief before Preview work.
3. **Precise fix:** approved UIKit/storyboard profile; change only
   `profileTitle`'s leading constraint from `20` to `16`.
4. **Delegated website details:** existing SwiftUI-For-Web; bold editorial large
   system type and a warm palette, no reference app, approved pitch/features,
   details delegated. Do not default to Apple/Airbnb; give an initial direction.
5. **No-motion refinement:** approved landing-page layout/copy and an available,
   licensed brand typeface; preserve those choices and remove all motion,
   including hover and scroll.

## Observations and corrections

| Attempt | Observation | Result within intake scope |
|---|---|---|
| First: 1–4 | Missing-direction response combined reference/style and omitted likes/dislikes. Website response imposed a cinematic parallax section. | Failed those boundaries. Added direct UI discovery routing; removed mandatory website motion and conflicting font defaults. |
| First: 2–3 | Preview brief reused supplied likes/style, distinguished missing evidence and proposed Save/Undo without the collection gate. Precise storyboard fix skipped discovery. | Passed those intake boundaries. |
| Second: 1, 4–5 | New UI response still chose a presentation without questions. Website reused the editorial direction with a static showcase; refinement preserved brand type and removed motion. | UI intake failed; website boundaries passed. Rewrote UI's primary job and canonical first step to clarify before presentation, and distinguished omitted preferences from delegated choices. |
| Final: 1, 3 | New UI response asked for reference apps, likes/dislikes and style/brand/motion preferences before presentation. Precise storyboard response retained the one-constraint scope without a design interview. | Passed the corrected missing-direction and precise-fix intake boundaries. |

Independent source review found no actionable routing or scope issue after the
corrections. The shared guide remains conditional: approved Figma frames,
precise fixes and export/packaging tasks skip discovery; answers travel in one
brief so specialists do not repeat the interview.

## Limits

These are observed intake responses and supplied-fixture interpretation, not a
success-rate estimate. The earlier failures remain part of the record. No live
competitor app or official product page was inspected, and no Apple HIG research,
Preview, Figma, Simulator, screenshot, site rendering, build or publication was
performed in these scenarios. End-to-end research, design fidelity, performance
and app behavior remain unverified by this change. Local repository validation
checks structure/links; it does not prove agent behavior.
