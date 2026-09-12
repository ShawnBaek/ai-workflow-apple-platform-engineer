# Focused verification and reviewable delivery

## Choose checks by risk

| Change | Useful baseline |
|---|---|
| Prose or metadata | Relevant schema, routing and link checks |
| Logic or bug fix | Observable changed behavior and a regression for the original failure |
| Authorization, lifecycle or shared contracts | Valid flow plus meaningful denial, expiry, race or terminal cases |
| Visible UI | Affected build, relevant states, and screenshot comparison |
| Interaction or motion | Critical flow plus trimmed recording; a durable UI test when justified |
| Data migration | Representative existing store and clean install |
| Performance | Reproducible before/after metric on the same toolchain and destination |

Do not mirror implementation details, duplicate one assertion at several layers, or require a coverage percentage. Use Swift Testing for new suitable logic tests; retain XCTest where the existing project or UI/performance APIs need it. Prefer existing fixtures and test targets. Record material omitted checks and limits once in the evidence report. Full suites and device matrices need shared impact, release risk, or an explicit request.

## Split the work

Before implementing broad work, identify slices that each answer one reviewer question and leave a valid state. Separate unrelated changes. Stack genuinely dependent PRs and link a shared ordered plan; each PR needs only its immediate dependency, intended base and focused checks. Keep a migration atomic when a split would leave incompatible runtime/contracts or broken consumers. Avoid artificial micro-PRs and repetitive phase bookkeeping.

Review the split when scope changes. Complete all authorized implementation and evidence preparation before any required publication approval. Existing account/destination answers remain valid within their approved scope. Commit, push, PR creation, merge and retarget permissions are distinct; obey the repository's actual policy.

A local deliverable can finish at `local_verified`. Do not create a GitHub issue or PR merely to complete a preview. The PR profile uses its configured Issue/Project tracking and requires current independent review and external readback; a failed Project update does not undo a successfully created PR.

The lead owns the selected delivery target through completion. For an authorized
PR task, a worker's finished code or local report is a handoff, not a stopping
point. Prepare the concrete commit/PR/evidence before any missing final approval,
then continue automatically through the authorized steps. Carry the checkout,
remote/base, account and granted actions from intake; do not make the user
rediscover them or repeat settled answers. If only a gate or external dependency
remains, name that exact item and preserve the prepared result.

## Capture useful proof

Keep detailed provenance in a linked report: base/head or patch identity, relevant Xcode/SDK/OS/destination tuple, command, outcome, acceptance criterion, artifact hash, and meaningful limits. Build-for-testing products are reusable only for a matching toolchain, package resolution, configuration and test destination. Do not label a Catalyst check as native macOS or iOS coverage.

For UI, show the actual changed state. For Figma parity, use [clean and aligned comparisons](../../screenshot/references/aligned-comparison.md). For motion, trim setup and idle time unless launch is the feature. Inspect playback and the meaningful first/last frames; preserve the original hash, trim window, output hash and any re-encoding in the report. JSON requests/responses are useful proof for data behavior when sanitized and tied to the related logic.

Choose proof during task breakdown so verification produces it: screenshots for
layout, a trimmed recording for changed interactions/motion, and a focused test,
JSON result or trace for hidden logic. A screenshot does not prove deck wrapping,
pause/resume or cancellation. Reuse existing capture/test support; do not add an
XCUITest framework merely to obtain a short recording. Required proof that cannot
be captured or published remains an explicit incomplete item, not an attachment
claim. Mark fixture behavior and older footage precisely; refresh evidence when
its relevant behavior changes.

Before publication, inspect artifacts for private account details, tokens, notifications and personal data. Keep private harness files and raw run ledgers out of attachments. Use `gh pr create --attach` / `gh pr edit --attach` for supported image/video evidence; follow the [standard GitHub CLI path](../../git-workflow/references/pr-delivery.md#standard-github-cli-path) for version discovery, partial uploads and readback. Use a small intentional evidence file or CI artifact for JSON/trace proof and record retention/expiry for temporary artifacts. Verify links and remote SHA after publication; after an ambiguous upload, inspect the existing PR before retrying.

## Review and publish

Use [code-review](../../code-review/SKILL.md) on an immutable patch. A different agent or independent perspective should reproduce relevant edge cases, cite code or authoritative references, and distinguish findings from uncertainty. For a UI issue, attach a focused screenshot or recording when Simulator access is available. Verify reviewer findings before changing code; record accepted, disputed, or deferred findings with reasons. Recheck changed behavior and invalidate stale evidence after a fix.

Use the repository PR template. Keep the body short: the problem and resulting behavior, checks with outcomes, a proof link, and a material limitation or dependency when needed. Put the full platform matrix, resource/token report, and review disposition in linked evidence rather than expanding every PR description. Never invent unavailable token counts or billing data.

After PR creation, publish the independent findings or a concise no-findings
summary through `code-review` when comment publication is authorized. Reuse an
unchanged pre-publication review after matching its patch to the remote head.
The author reads the posted feedback and checks its evidence before accepting
or disputing it. Verify the review URL/ID as well as the proof links; a local
review transcript or a sentence in the PR body is not a posted review. Keep
unavailable publication explicit and never represent agent feedback as human
approval. Merge remains a separate authorization.

When the guarded runtime is selected, revalidate the exact request, live lease, repository state and current evidence immediately before each external operation. Read back the accepted remote state and release resources after completion or a recorded failure. An ambiguous response requires action-specific readback before a fresh authorized attempt; the local fence is not remote exactly-once delivery.

Private completion messaging is separate from PR publication. Rendering `delivery-report` is read-only. Sending requires explicit authorization for the exact channel, destination, report, media and transport under the [delivery contract](../../delivery-report/contracts/delivery-authorization.schema.json). A configured channel is not permission to send.
