# Contributing

Help an agent make a better decision or complete a real task reliably. Start with a reported failure or a concrete improvement and the smallest evidence that will show it works. Read [AGENTS.md](AGENTS.md) for repository boundaries and approvals.

## Report a problem

Ask your agent to **use `skill-maintenance` to report this problem**, or open an issue using the [report template](.github/ISSUE_TEMPLATE/skill-problem.md). Include the loaded skill/version, expected and actual behavior, a small reproduction and relevant evidence. Unknown details are fine. Keep private sessions, app code and account information out of public reports.

The agent searches existing issues, prepares a sanitized report and publishes when authorized. It then returns the issue URL or a concrete publication blocker. Reporting does not require contributing a fix. GitHub displays issue templates after they reach the default branch. [GitHub template guidance](https://docs.github.com/en/communities/using-templates-to-encourage-useful-issues-and-pull-requests/about-issue-and-pull-request-templates).

## Find the right place to change

| Concern | Owner |
|---|---|
| Trigger, routing or task instructions | The affected `skills/<name>/SKILL.md` and its relevant reference |
| Collection entry points | `skills/native-app-lead/SKILL.md` and `docs/skills.md` |
| Reporting and repair | `skills/skill-maintenance/SKILL.md` |
| Enforced workflow, capability or authorization shape | `skills/agent-harness/contracts/`, its schemas, templates and fixtures |
| Runtime behavior and regression tests | `skills/agent-harness/verification/Sources/` and `Tests/` |
| Contributor/CI experience | `CONTRIBUTING.md`, `docs/verification.md` and `.github/` |

## Add a skill

Extend the existing owner when its trigger already covers the task. Add a skill only for a distinct capability with clear input, outcome and neighboring routes.

Create `skills/<lowercase-hyphenated-name>/SKILL.md` with frontmatter matching the folder:

```yaml
---
name: example-skill
description: Describe the task it handles and when to select it.
---
```

Keep the entry point focused on decisions an agent could otherwise get wrong. Add a reference only when substantial conditional detail needs it, and link it from the entry point. Avoid empty scaffolding, copied Apple manuals, a second router for one action, and requirements for irrelevant tools. Keep the installed skill usable without assuming the repository's contributor files are installed too.

Use official Apple/Swift documentation and applicable WWDC sources for API claims. Check the selected SDK and the app's minimum OS separately; do not raise deployment targets to simplify an example. Preserve existing storyboard/code/hybrid approaches and project architecture unless the task justifies changing them.

Add the skill to [the catalog](docs/skills.md) and the relevant lead route. Add it to health requirements only if that selected workflow truly needs it; installing one skill must not require every optional integration. Keep existing skill IDs stable. Update `VERSION` and the README version together only when preparing the agreed release.

## Fix or improve a workflow

Read the report and relevant source before choosing a solution. Record the observable failure and the intended result; a cited document alone does not prove that its API applies to this SDK or execution path. Reproduce the smallest case, or state what prevents reproduction.

Change the narrowest owning instruction or implementation. Update coupled schemas, templates, fixtures and call sites together. Preserve allow/deny, ownership, expiry and completion behavior; never weaken a check simply to make a fixture pass. A runtime identity or state-schema change needs an explicit compatibility/migration decision. Do not auto-refresh private approvals or installed user configurations.

Consult existing ADRs. Record a new ADR for a consequential architectural or compatibility tradeoff, not every wording fix. Use a simple plan by default; introduce a graph only for actual dependencies. Split unrelated improvements into coherent PRs and keep a migration together when an intermediate state would be invalid.

## Verify the change

Use the [workflow test plan](docs/workflow-test-plan.md) for repeatable scenarios,
pass criteria and a compact evidence record. Select the affected checks below;
do not treat every scenario as mandatory for every PR.

| Change | Smallest useful proof |
|---|---|
| Typo, link or compact documentation edit | Inspect the changed content and run the repository validator |
| New skill or changed decision/routing guidance | Replay one representative request and the nearest confusing case; inspect decisions and output, not just matching words |
| Bug fix in runtime or contracts | A Swift regression that fails for the original defect, passes after the fix, and preserves the relevant denial or boundary case |
| Shared authorization, resource or lifecycle change | Relevant expiry/replay/contention/terminal regressions plus the full package and repository checks |
| Visual or interaction guidance | A small real example when necessary; aligned screenshots for geometry, a recording for motion; state what was not exercised |

For a skill evaluation, give a fresh agent the changed skill, a realistic user request and only the raw fixtures needed. Keep the evaluator's expected outcome separate so it is not prompted to agree with the author. Use a bounded lightweight agent for simple routing; escalate only when the work requires it. Disable live writes or use mocked tooling during reporting tests. Record the selected route, proposed/performed actions, artifacts, result and limitations. A schema pass does not prove instruction quality, and one successful agent run does not guarantee every model will behave identically.

For example, test a `skill-maintenance` report from a private app checkout: the draft must target this collection, omit private material and respect the actual publication scope. Also try an app-only bug: it should route to the app owner rather than automatically creating a collection issue. Compare these outcomes before and after an instruction fix. Add cases for demonstrated regressions, not every imagined edge case.

From this repository root, with macOS and a full Xcode Swift 6 toolchain:

```sh
# Build only if the verifier is not already built for the current source/toolchain.
swift build --package-path skills/agent-harness/verification --product apple-verify -j 1 -Xswiftc -j1
APE_BIN_DIR="$(swift build --package-path skills/agent-harness/verification --product apple-verify -j 1 -Xswiftc -j1 --show-bin-path)"
"$APE_BIN_DIR/apple-verify" repository --root .

# For runtime/shared-contract changes; CI runs this suite too.
swift test --package-path skills/agent-harness/verification -j 1 -Xswiftc -j1
git diff --check
```

Use `DEVELOPER_DIR` for a per-command Xcode selection when needed; do not alter the user's global toolchain. The validator checks metadata, links, JSON/schema and runtime contracts; the Swift suite checks behavior. See [verification details](docs/verification.md). New custom verification helpers/tests use Swift. Reuse supported tools such as `gh`; do not add a report daemon, a second runtime or XCUITest infrastructure for a documentation change.

## Submit and follow through

Follow the actual account, commit, push and PR approvals. Use the [PR template](.github/pull_request_template.md): explain the problem/result in one or two sentences, list meaningful checks and link a small proof. Link the issue; use a closing keyword only for a complete fix intended to close it on merge. Keep logs and detailed review findings in linked evidence.

An independent reviewer should check the changed behavior and provide supporting code, reproduction or references. The author evaluates each finding and verifies accepted fixes. Report required CI as observed, then wait for authorized human merge. A draft, a passing local check, a merged fix and an available installed version are different outcomes; tell the reporter which one is known.
