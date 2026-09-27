# Changelog

Notable changes to Apple Platform Engineer, in the format of [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The version label comes from [`VERSION`](VERSION). Versions before 2.0.0-beta.10 were not recorded here; see the Git history.

## [Unreleased]

### Migration

- **Run authorizations are bounded.** `expires_at` may be at most 24 hours after `issued_at`, and `limits` allow at most 10 implementation attempts, review cycles and transient retries and at most 1,440 active or asynchronous-wait minutes. `initialize-run`, `prepare-action`, `authorize` and `verify-reservation` reject a larger envelope, and the approved schema's digest changed, so approve a fresh authorization within these bounds; see [run authorization](skills/agent-harness/references/run-authorization.md).
- **Run ledgers keep a head checkpoint.** `authorize` and `verify-reservation` write `<ledger>.head.json` beside the ledger and refuse a ledger truncated or rewritten below it, so an in-place rewrite cannot make a reserved or claimed grant usable again. Once the ledger holds a reservation or claim, a missing head blocks the run; leave the file in place. The ledger check also rejects a sequence gap.
- **`spec-snapshot` checks the installed Spec Kit CLI.** It runs `specify --version` once and fails as a migration candidate when the `specify` on `PATH` does not report `v1.0.1`; select the pinned CLI or review the adapter for the new release. See the [Spec Kit adapter](skills/agent-harness/references/spec-kit-adapter.md).
- **`runtime_probe_scope` names a probe run.** The scope now holds `harness`, `owner_run_id`, `plan_id`, `descriptor` and `ttl_seconds`, and health derives the probe run's authority live from that harness, its authorization and its ledger. The old shape, with `state_path`, `owner_actor` and a copied `run_authority`, could never name the harness's own run and now fails the harness schema as `untrusted_binding`. Set up a separate probe run whose resource plan holds the `coresimulator_runtime_registry` admission, then rewrite the scope as described in [runtime probe scope](skills/agent-harness/references/coordinator-setup.md#runtime-probe-scope) when you rebind the harness. Harnesses with a null scope are unaffected.
- **`resolve-project --registry` with a signal returns the registry projection.** With `--explicit-path` or `--opened-xcode-container`, the registry is now read. The call resolves as `registry_candidate` only when the registry lists that checkout and opened container, and it returns `opened_xcode_container_not_registered` (blocked) or `authoritative_target_not_registered` (unavailable) otherwise. An unreadable registry blocks the call. Resolve a target that is not in the registry without `--registry`.
- **Harness paths are absolute in the schema; the policy template starts unscoped.** `harness.schema.json` now rejects a relative or placeholder `authoritative_root`, `xcode_container`, `private_policy_overlay`, `run_authorization` or `run_ledger`, so `materialize` no longer writes a harness that still says `<absolute-path>`. The runtime already refused those values, so a harness that worked before still validates. `templates/private-policy-overlay.json` now has `"github": null`, which a local outcome keeps; for PR delivery set the approved owner. These contract and runtime changes alter the source-bundle SHA-256, so observe `runtime-identity` again and review the private bindings.

### Added

- `templates/run-authorization-local.json`, a pending authorization for `local_verified` runs whose `local_requirements` match `templates/harness-local.json`; `apple-verify repository` validates it as it does the PR template and keeps each template on its own delivery target. See [run authorization](skills/agent-harness/references/run-authorization.md).

### Changed

- [ADR 0002](docs/adr/0002-finalize-expired-quiescent-leases.md) is accepted. It shipped in 2.0.0-beta.10, whose entry below still calls it proposed.
- `trello-pm-card-sync` resolves a target version only when the board tracks target versions or you ask for one, and asks for it together with the proposed card instead of holding back the rest of a normalization. For a new screen in an app with an established style, UI and Preview design discovery follows that style instead of asking the reference and style questions.
- `apple-development-health` never builds, tests, installs, launches or boots a Simulator device; its runtime matrix cites those layers from the owning skills' evidence. The guarded runtime's documentation states that its authorization gate is agent-attested and when it is worth using, and `agent-harness` adds a worked local example.

### Fixed

- A schema `pattern` `$` matches only at the end of input, as JSON Schema's ECMA-262 dialect requires, so a digest, path or identifier with a trailing newline no longer passes. A schema keyword whose value has the wrong JSON type now fails closed instead of being skipped.
- The resource coordinator drops a released or recovered lease seven days after both its transition and its owner's authorization window ended, so its state no longer grows with every acquisition. The state schema is unchanged and older schema-2 runtimes still read it; see [state retention](skills/agent-harness/references/coordinator-setup.md#state-retention) and [ADR 0004](docs/adr/0004-bound-coordinator-lease-history.md).
- Health no longer traps on a resolved project registry candidate that lists an Xcode container, and the documented resolver call for an Xcode task or explicit root produces a resolution health accepts.
- `apple-verify repository` now checks every file under `skills/*/contracts` and `skills/*/templates`: each template and contract instance must be validated against a schema that agrees with its own `$schema`, and each schema must validate a shipped instance or fixture. The private policy template had never been validated, and the delivery authorization schema had no instance to validate. Digest fields keep one spelling each, and a new one must use the `sha256:` prefix.
- The IconGen watcher check accepts a reviewed runner-image, timeout or checkout-commit bump without a Swift edit, and now also catches an extra action written as `- uses:`.
- The skill-description budget measures a SKILL.md with CRLF line breaks, which it skipped, and measures a quoted description without its quotes and escapes.
- CI no longer cancels validation of an earlier push to `main`, and its `validate` job sets and records Xcode 16.4 as the repository's compatibility-floor lane. `xcode-project-workflow` treats a CI job that the repository documents as such a lane as a minimum, not a pin, so local work here keeps the newest installed Xcode 16.4 or later.

## [2.0.0-beta.10] - 2026-09-27

This entry covers the 49 pull requests merged to `main` after 2.0.0-beta.9, which landed with #38 (commit `5f0ccae`): [#39] through [#91]. Several changes break existing installations or private guarded-runtime harnesses, so read Migration first.

### Migration

- **Repository renamed** ([#39]). The collection moved from `ShawnBaek/iOS-experts` to `ShawnBaek/ai-workflow-apple-platform-engineer`. Install, update and report against the new name, and point a linked checkout's remote at it.
- **Lead skill renamed** ([#42], commit `3c49392`). `native-app-lead` is now `apple-platform-engineer`, and updating the old name does not install the new one. Install `apple-platform-engineer` with your original method, let old-name tasks finish or cancel, then back up and deactivate `native-app-lead` in the client's skill roots so one lead remains; an old-name link to the new folder is not an alias. Invoke `$apple-platform-engineer` in Codex or `/apple-platform-engineer` in Claude Code. A private harness reviews `agent_skills.task_skills` for the old name and collects fresh health evidence before its next authorized run. See [Rename an existing lead installation](docs/getting-started.md#rename-an-existing-lead-installation).
- **New skills** ([#47], [#48], [#51], [#52], [#60], [#66], [#82]). Add the ones you want with the install command and their names. `open-xcode-handoff` and `apple-platform-setup` are now in the [starter set](README.md#get-started); `app-store-screenshots`, `figma-golden-testing`, `trello-pm-card-sync`, `sketch-design-from-codebase` and `release-qa-handoff` are optional. A versioned bundle's pointer switch does not change its skill links: add links for new skills and prune `native-app-lead` as the [update procedure](skills/apple-platform-setup/references/updating.md#reconciling-the-per-skill-link-farm) describes ([#64]).
- **Keep `agent-harness` installed; guarded execution is opt-in** ([#85], [#88]). `CLAUDE.md` and `AGENTS.md` now load `apple-platform-engineer` for broad or end-to-end work, and `agent-harness` only when guarded execution is selected or a change touches the harness runtime or contracts. Update project instructions copied from the old `CLAUDE.md`, which sent broad work to `agent-harness`, and invoke `apple-platform-engineer` wherever you or your instructions used `agent-harness` for broad or end-to-end work; its description now says it is not for ordinary feature or PR work. Keep the `agent-harness` folder installed anyway: the lead and many specialists link its shared references, and installing it builds or configures nothing.
- **Private harnesses: rebuild and observe `runtime-identity` again** ([#72], [#74]). Updating to this release changes the verifier's source bundle (JSON under `contracts/`, Swift under `verification/Sources`), and with it the source-bundle SHA-256, whatever the installation path, so existing `resource_coordinator` and `authorization_runtime` bindings fail by design. Notable causes: the one-time swift-format pass over the verifier sources ([#74]) changes the digest even where behavior is unchanged, and the physical-path naming fix ([#72]) gives an installation under an aliased path (`/tmp`, `/var`, `$TMPDIR` or a linked parent) its corrected digest once. Finish or safely recover active leases, [build and locate the verifier](skills/agent-harness/references/swift-verification.md#build-and-locate-the-verifier), run `runtime-identity`, review and update the private bindings, rerun health, and start a fresh run authorization and ledger. Never auto-rehash an approval or rewrite a historical ledger.
- **Local guarded harnesses** ([#41]). A `local_verified` harness now requires `github_tracking.issues: false` and `project: null`. The beta.9 schema forced `issues: true`, so correct any private local harness written for it, or health, run initialization and authorization reject it as `untrusted_binding`. PR and TestFlight harnesses keep `issues: true`. To check an external app, pass `--app-root <absolute-app-repository>` before the subcommand; `--repository-root` still names the skills repository.
- **`quiescent_release` lease mode, ADR 0002** ([#50]). `recover` gains an evidence mode that finalizes expired, quiescent leases without takeover. The new runtime still reads schema-2 state and old evidence, but old strict runtimes cannot read a record with the new evidence mode, and downgrade after first use is unsupported. Upgrade every runtime that reads the same coordinator state before any of them uses the mode. See [ADR 0002](docs/adr/0002-finalize-expired-quiescent-leases.md) (status: proposed).
- **Guarded workflow spine** ([#55]). New runs use `select_task_branch` in place of `branch_approval`. Existing runs keep their pinned bundle and recorded gates; adopting the new spine needs a new run with current source identity and authorization. Do not rewrite persisted ledgers or Spec Kit `approved_git_branch` fields.
- **`git.commit` grants take a path scope** ([#70], [#73]). `operation_input.paths` is now an approved path scope with the `allowed_paths` prefix rule rather than an ordered file list, and the request must name exactly the live reviewed staged set, in any order. Existing exact-list grants keep working, but a directory entry in an already-approved grant, which could never match before, now authorizes any staged file beneath it, so review such grants before reuse. From [#73], observed staged and outgoing paths now list both sides of a rename, so a commit or push request containing a rename must also name the source path, and a rename out of a directory outside `allowed_paths` is denied.
- **Stricter guarded-runtime inputs** ([#90], [#91]). Pass absolute paths: the coordinator, `initialize-run` (including `--run-root`), health and authorization commands refuse relative ones. Set `runtime_probe_scope.ttl_seconds` to at least 90, or the `simulator.runtime` probe reports `runtime_probe_lease_too_short_blocked`. Automation that matched `invalid_request` should also handle `coordinator_busy`, `io_error`, `untrusted_binding` and `untrusted_authority`. After a `stop` record the run can no longer acquire or heartbeat a lease, reserve, dispatch or record an external write; a `rejected` repository decision after the approval revokes it for the rest of the run; the ledger check rejects an `external_write` recorded after its dispatch deadline (at most 60 seconds), so when a call returns late, stop the run as `blocked` without recording it and continue with live readback and a fresh authorization. Reservation and dispatch compare live health with the approved status: it may recover from `degraded` to `healthy` without reapproval but blocks when it falls below the approved status. Hand-appended ledger records follow [run authorization](skills/agent-harness/references/run-authorization.md): 0x0A line endings, the next sequence and no backdating.
- **Health probes** ([#71]). `testflight.internal_groups` runs `asc testflight groups list` (asc 0.38.0 or later) and requires every authorized group ID to be a live internal group. `github.issue_pr` accepts organization-owned repositories through the viewer's repository permission instead of comparing the `gh` login with the policy owner.
- **Swift format and compile gate** ([#74]). Swift changes are formatted with swift-format, linted and compiled without errors before completion, without reformatting code the task did not touch. Contributors format with swift-format 604.0.0 and the root `.swift-format`; the new CI job fails on formatting drift. Rebase open branches onto the one-time reformat and rerun the formatter on conflicting files.
- **Reviewer approval before PR publication** ([#75]). A pull request is opened only after an independent reviewer approves its exact current head, within two review rounds by default (`max_review_cycles` in the guarded runtime). When the rounds run out or no independent reviewer is available, the agent does not publish and asks you to decide; any later change to the reviewed content needs re-review. The approval is an internal gate, not a GitHub approval or merge authority.
- **Newest installed Xcode by default** ([#84]). Without your choice or a repository pin such as `.xcode-version`, agents use the newest installed full Xcode, betas included, per command through `DEVELOPER_DIR`, and never change `xcode-select`. Beta-Xcode builds are TestFlight-only, so anything that may reach App Review needs a release Xcode or an App-Store-eligible RC; if none is installed or eligibility is unclear, the agent stops and asks. Name or pin an Xcode to use another one. Binding the Xcode MCP bridge to the selected Xcode is persistent configuration that needs your approval and a client restart.
- **Shorter skill descriptions** ([#85]). Each description now fits 300 characters and the collection 9,000, which the validator enforces; the shortening left skill bodies unchanged. A 12-request routing replay from descriptions alone chose the same skills before and after. Rebuild any local frontmatter override from the new text.
- **Tracker writes need a request** ([#86]). `release-qa-handoff` changes tracker cards only on an explicit request in the task or one batch confirmation; a merge or processed build is only a reason to offer the handoff. What to Test notes publish through `app-store-connect` under its account guard.
- **Rebuild a local knowledge index** ([#89]). The stricter secret filter applies only to files indexed from now on, so an index built with beta.9 can still hold secret-format files. Delete the index database with its `-wal` and `-shm` files and rebuild it with `knowledge index`, which creates it 0600; an existing index directory keeps its mode, so set it to 0700.

### Added

- `apple-platform-setup`: first-run dependency setup and capability verification, with the update procedure inside the installed skill ([#47]).
- `app-store-screenshots`: App Store screenshots and preview videos tied to the intended version, build and source ([#48]), with editable Keynote layouts per platform canvas ([#54]).
- `figma-golden-testing`: compare a capture with a node-specific Figma frame through overlay, diff, side-by-side, metrics and visible-text checks ([#51]).
- `trello-pm-card-sync`: turn rough Trello cards into agent-ready work and sync confirmed delivery state on request ([#52]); confirm the target marketing version before writing an app Todo card ([#56]); English card text and TestFlight readiness in card titles ([#63]).
- `sketch-design-from-codebase`: Sketch design systems and screens built from source and real captures, with SF Symbol and logo rendering helpers ([#60]).
- `release-qa-handoff`: correlate a processed build with its merged PRs and tracker cards, stamp version and build, and draft the What to Test note ([#66]).
- `open-xcode-handoff`: apply an agent's worktree, sandbox or cloud change set reversibly to the checkout open in your Xcode and verify it there ([#82]).
- Design discovery before a new UI direction: reference apps, flows, likes and dislikes and preferred style, shared across UI, Preview, Figma, website and icon work ([#40]).
- Update guide for Skills CLI, linked-checkout and versioned-bundle installations, and bounded delegation of several tasks within agent, writer and build limits ([#43]).
- App Store Connect routes for local archives, Xcode Cloud builds and processed-build reuse, with upload and wait boundaries ([#46]).
- MIT license and project-selected tools, design sources, tracking and approval policies, with synthetic public examples ([#53], [ADR 0003](docs/adr/0003-separate-consumer-preferences-from-runtime-contracts.md)).
- `quiescent_release` recovery for expired, quiescent leases that preserves work and fencing and grants no replacement ownership ([#50]).
- Validator fixture `tests/fixtures/skill-routing.json`: capability-routing and rule-consistency cases fail validation when a shipped routing or exception fix is undone ([#65]).
- Root `.swift-format` (swift-format 604.0.0 defaults) and a CI job that fails on formatting drift, reports lint and type-checks standalone scripts ([#74]).
- Code-review checklist per change type: UI, structure, ViewModel inputs and outputs, OpenAPI-first networking, Apple-tool verification and pointless tests ([#75]).
- Standalone readiness check in `apple-development-health` and a standalone ownership check, neither needing the harness ([#88]).

### Changed

- **Breaking:** repository renamed to `ai-workflow-apple-platform-engineer`, with installation and reporting links and the IconGen watcher target updated; the README gains post-install commands and a workflow diagram ([#39]).
- **Breaking:** lead skill `native-app-lead` renamed to `apple-platform-engineer`, with callers and templates updated ([#42]).
- **Breaking:** `CLAUDE.md` and `AGENTS.md` route broad work to `apple-platform-engineer`, and `agent-harness` becomes explicit opt-in for guarded execution ([#85]) while staying a required companion in the starter set ([#88]).
- **Breaking:** agents default to the newest installed Xcode per command, with an App Store distribution exception ([#84]).
- **Breaking:** pull requests are published only after reviewer approval of their current head ([#75]).
- **Breaking (guarded runtime):** `git.commit` grants treat `operation_input.paths` as an approved path scope ([#70]).
- **Breaking (guarded local harnesses):** the local harness separates the app root (`--app-root`) from the installed verifier, and a `local_verified` harness requires `github_tracking.issues: false`, matching its template ([#41]).
- Skill descriptions fit a 300-character per-skill and 9,000-character total budget, with one usage clause and "Not for" routes to confusable neighbors ([#85]).
- Swift changes must be formatted with swift-format, linted and compiled without errors before completion ([#74]).
- App work needs a final integrated build and warning triage before it is reported complete ([#57]).
- PR delivery continues through authorized `gh` publication, inspected attachments, review comments and readback ([#45]).
- Task branch names come from the assigned work, fresh tasks start from the verified remote default, and existing changes are reported with a handling proposal before any mutation ([#55]).
- Simulator destinations are reused before any device is created; task-created devices are named, leased and deleted, and parallel-testing clones stay off unless required ([#83]).
- `release-qa-handoff` publishes What to Test notes through `app-store-connect`, writes tracker cards only on request or confirmation, and treats card content as data ([#86]).
- `commit-message` follows the repository's subject case, lowercase after the Conventional Commits colon by default, and commits only when the workflow authorized it ([#87]).
- `delivery-report` states that the collection ships no message transport and defines the contract a private one must meet ([#87]).
- Busy-resource responses keep bounded contention details and distinguish busy capacity from missing authorization ([#44]).

### Fixed

- Figma-parity testing routes to `figma-golden-testing`, which verifies assets, colors and geometry by measurement ([#59]).
- `figma-bridge` reads colors from the design source instead of judging or substituting them ([#62]).
- `figma-bridge` Code Connect guidance follows Figma's current docs: the `@figma/code-connect` CLI and `.figma.ts` templates, with `FigmaConnect` structs treated as legacy ([#81]).
- `figma-golden-testing` `diff.png` shows every counted mismatch, `text-results.json` is documented, and Figma exports match the capture scale ([#79]).
- `apple-platform-ui` UIKit, TextKit and keyboard samples compile and behave; the pre-ship audit accepts an Icon Composer `.icon` and keys the privacy manifest on required-reason API use ([#76]).
- `apple-platform-performance` corrects SwiftUI invalidation, hang tooling and MetricKit guidance and adds a headless `xctrace` recipe ([#77]).
- `core-data` and `apple-data` state CloudKit mirroring model limits, the additive-only production schema and SwiftData's private-database-only sync ([#78]).
- `app-website` store and share links are real anchors, SwiftUI-For-Web and the browser MCP are pinned, and 3D Apple product renderings need Apple's permission ([#80]).
- Bundle activation documents pointer relinking, link-farm reconciliation and local-only entries ([#64]).
- Installed skills no longer link into the repository's `docs/`, and the verifier build runs before `--show-bin-path` resolves its path ([#88]).
- Run-authority approval windows compare as instants, so equivalent RFC 3339 forms no longer drift ([#68]).
- The ledger accepts every schema node status and `improvement` record without granting progress ([#69]).
- Health probes accept organization-owned repositories and verify TestFlight internal groups with the current `asc` command ([#71]).
- Source-bundle digests name files relative to the physical skill root, so checkouts under `/tmp` or a linked parent no longer fail with `untrusted_binding` ([#72]).
- Coordinator leases, relative paths, error codes, ledger creation and duplicate TestFlight terminals fail precisely ([#91]).

### Security

- The IconGen watcher adopts only marker issues authored by `github-actions[bot]` ([#89]).
- `skill-maintenance` shows the exact final title, body and attachments and waits for confirmation before any public post ([#89]).
- CI checkouts and the `cicd` template set `persist-credentials: false` ([#89]).
- The knowledge index skips more secret formats and creates its directories 0700 and its database 0600 ([#89]).
- Self-hosted runner guidance keeps untrusted PR code off persistent runners, and the 1Password migration uses the app's Import .env file instead of an agent-written script ([#89]).
- Fail-open authorization paths are closed: a `stop` ends the run's authority, a later `rejected` repository decision revokes approval, dispatch re-reads the clock after health probes, and a direct Issue target must be the bound Issue ([#90]).
- Observed staged and outgoing paths list both sides of a rename, so content cannot leave an unauthorized directory unchecked ([#73]).

[Unreleased]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/compare/v2.0.0-beta.10...HEAD
[2.0.0-beta.10]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/compare/5f0ccaec01c246c87cf6a2fceab539f7e0e62c44...v2.0.0-beta.10
[#39]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/39
[#40]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/40
[#41]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/41
[#42]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/42
[#43]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/43
[#44]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/44
[#45]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/45
[#46]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/46
[#47]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/47
[#48]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/48
[#50]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/50
[#51]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/51
[#52]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/52
[#53]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/53
[#54]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/54
[#55]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/55
[#56]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/56
[#57]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/57
[#59]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/59
[#60]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/60
[#62]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/62
[#63]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/63
[#64]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/64
[#65]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/65
[#66]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/66
[#68]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/68
[#69]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/69
[#70]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/70
[#71]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/71
[#72]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/72
[#73]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/73
[#74]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/74
[#75]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/75
[#76]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/76
[#77]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/77
[#78]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/78
[#79]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/79
[#80]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/80
[#81]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/81
[#82]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/82
[#83]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/83
[#84]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/84
[#85]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/85
[#86]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/86
[#87]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/87
[#88]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/88
[#89]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/89
[#90]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/90
[#91]: https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/pull/91
