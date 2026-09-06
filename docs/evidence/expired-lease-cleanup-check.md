# Expired lease cleanup verification

Scope: the cleanup/ledger defect in [#49](https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/issues/49),
based on main `1de93689a78b2309a3ef6d1a0c484fd5cb8e37ea`.
See [ADR 0002](../adr/0002-finalize-expired-quiescent-leases.md) for compatibility.

## Executed checks

Swift 6.4 from the selected full Xcode toolchain; one Swift compiler/build worker.
The full package passed **75 XCTest + 12 Swift Testing tests**. No third-party
dependencies, Python, Simulator sessions or XCUITest infrastructure were added.

| Check | Observed result |
|---|---|
| Original recovery-evidence validator restored | New capacity-restoration regression fails with `invalid_recovery_evidence` |
| Original ledger expiry check restored | New terminal-ledger regression fails with `lease coordinator receipt is expired` |
| Both corrections restored | Full suite passes |
| Cleanup preview | Coordinator bytes unchanged; projected capacity shown; no terminal confirmation |
| Live quiescent owner with expired authority | Exact registered authority finalizes only; stale receipt remains unusable |
| Completed owner, different client | Actual `apple-verify resources ... recover` subprocess previews and completes using the observer's harness, without an archived owner harness |
| Preserved work / unrelated lease | File bytes and unrelated receipt remain unchanged; later admission gets a higher fence |
| Unsafe evidence / replacement | Running children, incomplete state, bad fence/receipt, wrong observer, pre-expiry/future observations and replacement are rejected without writing |
| Dependent package work | Parent cleanup rejected until build lease is terminal; reverse-order cleanup succeeds |
| Audit integration | Schema and lifecycle accept the actual recovery confirmation; forged confirmation rejected |
| Review regressions | Registered outsiders cannot finalize a live owner; ledger transition times cannot be forged or recorded prematurely; delayed append of a proven timely normal release is valid while expired acquisition stays invalid |
| Existing dead-owner takeover | Existing lifecycle/replacement regressions continue to pass |

The sensitivity checks restore the original individual gates into the candidate;
they are not a claim that the entire old binary supports the new CLI or schema.
An initial CLI fixture failed because it mixed Codex installation settings with
a Claude caller. Correcting the fixture's client configuration made the real
subprocess pass; no production check was weakened for it.

## Limits and remaining work

Tests use isolated synthetic coordinator states and observations. They do not
replay private task recovery or prove that a client observes process quiescence
correctly. The runtime validates bound, fresh evidence within its cooperative
trust model; it does not discover or terminate OS processes.

Automatic heartbeat, task/child lifecycle attribution and installed-client
activation remain separate work in #49. This PR references the issue without a
closing keyword. No live coordinator, installed harness or private approval is
rewritten. The runtime, schema, ledger and their tests stay in one PR because
splitting that contract would leave an unusable intermediate cleanup path.
Live owners registered under an old runtime binding cannot use self-cleanup after
upgrading their harness. Once completed, their expired leases can be finalized by
a fresh active observer. This installation boundary was established by source
review; no live runtime upgrade was performed.
