# Task handoff regression check

Date: 2026-09-06. Baseline: `572659db7fd56b1b13abb93cb48e9433dfa1773f`.

Two inspected app tasks exposed repeated setup/approval handoffs, local stopping
points before later PR requests, and no posted PR reviews despite local reviewer
work. One PR had screenshots; the other had screenshots, recordings and passing
Xcode Cloud checks. This is not a claim that both lacked proof or that legitimate
commit/account gates should be removed. The observed startup failure was an
installed runtime/root mismatch, not proof of four stale leases. Private task
transcripts, paths and account state are excluded from this report.

## Fresh-agent walkthrough

Separate fresh agents received the same three synthetic cases and eight relevant
skill/reference files from the baseline or candidate snapshot. Selected model:
`gpt-5.6-luna`, medium effort. Expected outcomes were not in their prompts.
These were proposed-action walkthroughs: source reads occurred, but Git/ASC,
coordinator, builds and publication were not executed. Tools were not technically
sandboxed; no mocked transport or permission-denial result is claimed.

| Case | Baseline observation | Candidate observation |
|---|---|---|
| Repeat-all is verified; PNG/MP4 inspected; independent review found no defects. User requested PR and review comments. Account/destination/branch confirmed; immediate commit approval missing. | Asked only for commit approval and continued to PR/proof/checks after approval, but omitted publishing the requested review. **Failed** that completion criterion. | Presented concrete publication inputs, asked for commit approval, then included PR, proof, no-findings review comment and remote head/base/review readback. **Passed** the planning rubric. |
| Same change, explicitly local-only | Completed locally without publication. **Passed**. | Completed locally without publication. **Passed**. |
| Five tasks, three child slots; build capacity busy, source writer free, owner unknown | One writer plus independent readers; queued build without takeover. **Passed**. | Same resource boundary; explicitly retained `capacity_exceeded`, continued independent work and required no permission to wait. **Passed**. |

The candidate kept one repository writer, reused settled intake, and preserved
the explicit commit gate. Case A specified that gate as missing; it did not
exercise a separate first-PR confirmation policy. Where such a gate applies,
the final request must explicitly cover it, or PR creation remains pending.
This sample supports the stated decision changes;
it does not measure five concurrent app implementations, latency, memory, disk
reuse, cancellation, or a reliable cross-model success rate. No new XCUITest or
runtime orchestration layer was introduced for these guidance changes.

Repository validation and independent source review supplement this walkthrough.
Required follow-up integration remains a real authorized app task through PR
publication, visible media, reviewer COMMENT, author disposition and readback.
Do not label this synthetic result as live end-to-end delivery.

The subsequent `gh` standardization was checked against installed **2.99.0** help
and the official create/edit manuals: both commands support image/video
attachments, local image-reference rewriting, and partial-success readback.
The proposed command examples were inspected; this change did not upload media.
