# Reporting workflow walkthrough

An independent agent read `skill-maintenance` and walked through three raw request/tool-response fixtures. Publication was simulated: no issue, comment, app edit or Simulator action was performed. The expected outcomes were checked against the proposed actions, not exact wording.

| Scenario | Observed decision | Result |
|---|---|---|
| Explicit report request from a private app checkout; testing guidance adds a large XCUITest harness for a README typo; installed revision unknown | Targeted `ShawnBaek/iOS-experts`, retained unknown version and unverified cause, omitted the fixture token and private path, proposed one issue create followed by readback using the confirmed fixture account | Passed |
| App storyboard crash caused by a stale IBOutlet; user requests an app fix | Routed to the consuming app, proposed repairing the connection and a focused build/run check, proposed no upstream report | Passed |
| Earlier issue create timed out; search/readback finds the matching submitted report; no new evidence | Reused the existing report, proposed no duplicate create or comment | Passed |

The report draft used five short sections: skill/version, expected and actual, reproduction, relevant environment, and evidence/workaround. It described the testing behavior as a hypothesis because the loaded instruction and original agent rationale were unavailable.

Author review also clarified the issue-only path in the GitHub skill: a report does not require a checkout, branch, Project or PR. An active harness without authority for the upstream action must retain the draft and explain the limitation. These wording changes received source review and repository validation; they were not a fourth agent execution.

This is one instruction-following walkthrough, not a live GitHub integration test or a guarantee across models..
