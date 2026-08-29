# Minimum-sufficient verification and PR delivery

## Select the smallest defensible checks

| Change | Required baseline |
|---|---|
| prose/format only | skill/schema and relative-link validation |
| skill routing/metadata | baseline plus one positive and nearest-collision negative route |
| deterministic graph/schema | one valid, one malformed, one terminal-state case |
| bug fix | one regression that reproduces the original failure |
| pure logic | changed branches and material boundary/failure only |
| visible UI | affected build, one critical flow, relevant visual evidence |
| interaction/motion | affected build/flow plus video or UI-test recording |
| data migration | representative old-to-new store and clean install |
| external mutation/safety | static allow and deny contract; no live destructive eval |

Do not duplicate the same observable contract at unit, integration, and UI
layers. Do not add a test whose infrastructure is larger than the change unless
the risk rationale says why. Do not use a blanket coverage percentage as a gate.

For every new test record `observable_contract`, `prevented_failure`, and
`unique_path`. Record omitted checks and the residual risk in evidence and the
PR body. Full suites/device matrices are reserved for shared core, release, an
explicit request, or an impact graph that justifies them.

## Evidence bundle

Record base SHA, `patch_identity_v1`, and commit-tree equivalence; Xcode build,
SDK, platform, OS, and architecture; project/workspace, scheme, configuration,
test plan, destination;
tool/provider/version; normalized command or tool call; start/end/exit state;
`.xcresult`, screenshot, and video path plus SHA-256; and an observed result for
each acceptance criterion.

Keep platform claims separate: iPad window/size class, watchOS Crown/button and
pairing state, macOS native versus Catalyst, and iOS destination are not one
generic “Apple build passed.” Reuse a built-for-testing product only when the
entire toolchain/destination/package/test-plan tuple matches.

## PR publication

Separate `prepare evidence`, repository confirmation, writer claim/commit/release,
GitHub claim/push/create PR/publish evidence/release, and `await checks`.
Reverify the current patch identity before repository confirmation and verify
the remote SHA after publication. Do not treat one approval as permission to
merge.

`gh pr create` has no documented arbitrary local-attachment flag. Use:

- small, policy-approved permanent images committed at an evidence path and
  linked by full commit SHA;
- GitHub's browser attachment flow for human-facing screenshots/videos;
- Actions artifacts for `.xcresult`, videos, and large logs, with digest,
  retention, and expiry stated in the PR.

Never use an undocumented upload endpoint or an expiring URL as permanent proof.
Before publication, scan media for accounts, tokens, email, location,
notifications, and personal status-bar data; decode images; verify video codec
and playback; then verify the PR preview/link from the intended viewer context.

The PR body must include summary, acceptance criteria, checks with results,
evidence links/digests, omitted checks and risk, platform/toolchain matrix, and
known limitations. A failed Project-board update is partial success and must not
roll back a valid PR.
