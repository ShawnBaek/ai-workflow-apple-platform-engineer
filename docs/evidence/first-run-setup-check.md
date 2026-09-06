# First-run setup verification

Scope: `apple-platform-setup`, install/update entry points and setup/health routing,
based on `572659db7fd56b1b13abb93cb48e9433dfa1773f`. This is guidance verification;
no clean-machine installation or full app workflow was executed.

## Proposed-action scenarios

Bounded agents produced proposed actions from sanitized fixtures. No installation
or account mutation was executed. These were planning walkthroughs, not an
intercepted tool test. Provider usage and execution costs were not measured.

| Fixture | Baseline / first candidate | Bounded recheck |
|---|---|---|
| Fresh client, Git/Homebrew present, `gh` and full Xcode absent; local iPhone + PR setup authorized, account/project unknown | Both unnecessarily delayed independent setup behind answers. | Candidate installs authorized `gh` while account answers are pending; scopes Xcode and runtime choices to the project, and defers account calls/harness bindings until their facts exist. |
| Staged update, two tasks reading the shared manifest, zero leases | Both kept the old bundle but asked a new wait/cancellation question. | Candidate continues independent setup, reports activation pending actual quiescence and preserves old grants. No permission-to-wait or default cancellation. |
| Explicit no-change buildability inspection, full Xcode present, Simulator runtime absent | Both proposed a build despite the no-change scope. | Candidate uses bounded observations, does not build/boot/install, and distinguishes observed prerequisites from compile success. |
| README typo, Git present, other dependencies absent | First candidate stayed local and narrow. Baseline misread the Git fixture as absent, so that baseline result is excluded from comparison. | Candidate uses existing Git and a focused edit without unrelated setup, harness, ADR or publication. |

The original outputs and one recheck were retained. Instructions were corrected
for independent setup, no-change inspection and active-consumer handling. These
few cases support those decisions; they do not establish an agent success rate.

A separate selective-copy walkthrough retained unknown commit metadata and skipped
the harness. Its first fixture omitted concrete paths and prompted extra scope
questions. One clarified fixture supplied settled paths and explicit dependency
authority; the proposed actions reused them and avoided an unrequested app build.
Actual recovery of an unidentified old snapshot remains unexecuted.

## Independent review and executable observations

An independent reviewer identified three issues and verified their
corrections: selective copies may lack a repository commit ID; lightweight setup
must not require harness-backed health; and update instructions must ship inside
the installed skill. The update procedure now lives in the setup skill's own
references. Missing provenance stays explicit and selected dependencies are
staged from one inspected snapshot rather than silently mixed.

On the existing macOS host, a Swift helper executed nine read-only probes:
Git, `gh`, `asc`, Xcode and Swift versions; `gh pr create/edit --help`; and
`xcrun --find simctl/mcpbridge`. All exited zero. Both `gh` help probes advertised
`--attach`. Tool discovery does not prove authentication, task MCP exposure,
Simulator execution or fresh installation.

The existing Swift repository validator passed with 35 skills and no errors.
No runtime source or contract changed, so the runtime suite was not repeated.
Moved update links and patch whitespace were checked independently.

## Remaining integration

Not run: installation in a clean client profile, an actual missing-tool install,
account authentication, MCP capability call, client reload, activation across
quiescent tasks, or a representative app build/launch. These require a selected
environment and task authority; no test PR, upload or signing mutation was used
as a setup probe. A future integration should verify the active skill paths and
one selected capability after setup, retaining any failure and rollback result.
