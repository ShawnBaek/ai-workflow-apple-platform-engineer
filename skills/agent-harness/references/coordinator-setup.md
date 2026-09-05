# Private host coordinator setup

Use one coordinator per logged-in development host, not one per agent, project,
or task. Its state and populated harness contain absolute local paths, so keep
both outside repositories and untracked. Codex and Claude must receive the same
exact run-specific harness file when they collaborate on the host.

Set one absolute installed-skill root before using any command below; commands
must not depend on the caller's working directory:

```sh
AGENT_HARNESS_ROOT='<absolute-installed-agent-harness>'
# Build once as described in the Swift verification setup.
APE_BIN_DIR="$(swift build --package-path "$AGENT_HARNESS_ROOT/verification" -c release --product apple-verify -j 1 -Xswiftc -j1 --show-bin-path)"
APE="$APE_BIN_DIR/apple-verify"
APP_ROOT='<absolute-authoritative-app-repository>'
HARNESS_TEMPLATE="$AGENT_HARNESS_ROOT/templates/harness-local.json"
# For PR delivery, select "$AGENT_HARNESS_ROOT/templates/harness.json" instead.
```

Build the [Swift verifier](swift-verification.md) first. For a local outcome use
`templates/harness-local.json`; set its review/Spec Kit flags from the accepted
plan and keep GitHub/Apple scope null. Use the PR template only for PR delivery.
Use the same toolchain/configuration/build flags when resolving the executable
path. Confirm `--help` includes `--app-root`; source edits alone do not update
an older binary. For app health commands, use `"$APE" --app-root "$APP_ROOT"`
so the checked repository stays separate from the installed contracts.

## First setup or schema migration

1. Choose an existing private directory owned by the developer. Do not create a
   coordinator path implicitly during a task.
2. Stop new mutations, let every earlier task finish or cancel its child tool
   calls, and explicitly confirm that legacy or unversioned leases are quiescent.
3. Bootstrap one state with the installed copy of the skill:

   ```sh
   "$APE" resources '<absolute-private-state-path>' \
     bootstrap --legacy-leases-quiesced
   ```

4. Materialize the approved private policy and harness outside the app
   repository. This rewrites repository-relative `$schema` values into
   resolvable installed-schema URIs, validates them, and writes mode `0600`:

   ```sh
   "$APE" materialize \
     --template '<installed-agent-harness>/templates/private-policy-overlay.json' \
     --schema '<installed-agent-harness>/contracts/schemas/private-policy-overlay.schema.json' \
     --output '<absolute-private-policy-path>'
   "$APE" materialize \
     --template "$HARNESS_TEMPLATE" \
     --schema "$AGENT_HARNESS_ROOT/contracts/schemas/harness.schema.json" \
     --output '<absolute-private-harness-path>'
   ```

   Populate only the policy's approved GitHub owner and optional Apple guard when those scopes apply; use null for a local outcome. Fill
   every harness field, including absolute private paths, exact coordinator
   binding, selected client roots, profile/components, repository, and Xcode
   container when applicable. For a TestFlight run, also configure
   `apple_observation_probe` with one absolute private executable, its exact
   `sha256:` digest, output contract `apple_observation_v1`, and a timeout no
   greater than 30 seconds. Never commit either file.
5. Run `"$APE" runtime-identity`. Populate `authorization_runtime` from the
   observed contract, executable path/hash and source-bundle hash. Populate
   `resource_coordinator` with runtime kind `swift`, contract
   `apple-verification-core.resources.v1`, those same executable/source hashes,
   the exact state path and bootstrap instance ID. The binary and installed
   Swift/JSON enforcement sources must match; build products are excluded from
   the source digest. This read-only command never approves a changed binding.

6. Derive the client-visible skill bundle before trusting the placeholder hash:

   ```sh
   "$APE" --app-root "$APP_ROOT" health \
     --harness '<absolute-private-harness-path>' --observe-agent-skills
   ```

   Copy the reported `expected_bundle_sha256` into the private harness, then run
   the same command again. This two-pass bootstrap detects mixed client copies,
   missing skills, broken symlinks, and an evaluator outside the selected roots.
7. Run `status`, materialize and populate `health-observations.json`, then run
   the `apple-development-health` gate. Both clients must
   observe the same canonical state path, instance ID, state schema, executable
   hash, and source-bundle hash before any acquisition.

Use the matching installed schema when materializing the optional private
registry or health report. Do not copy a repository-relative `$schema` value
unchanged.

Do not infer quiescence from one empty run ledger. Do not silently migrate an
old state, create a second state after contention, or use a symlinked state,
harness, or runtime executable.

Review the [host budget](host-resources.md). The default capacity is one heavy
job, one active destination and two internal workers. Change it explicitly with
`resources <state> configure-host-policy --policy '<exact-json>'`; increases
require `--operator-confirmed` and decreases cannot undercut active usage.

## Normal use

Create one existing, permission-restricted private run directory outside every
repository. Keep its authorization, request, Apple observation, append-only
ledger, receipts, and unredacted absolute descriptors there; never stage,
publish, screenshot, or attach that directory to a PR. The ledger file must be
a regular non-symlink file directly under that run root. Set that exact future
path as `run_ledger` in the run-specific private harness. Initialization binds
the canonical pathname, device/inode identity, and first approval record into
the coordinator. A second filename, copied ledger, hard link, or replaced inode
cannot authorize the run.

The private Apple observation executable is a no-argument read-only adapter. It
must first compare the active App Store Connect profile/account/team with the
private guard, then query only the authorized app and print one JSON object with
`source`, `guard_verified`, `observed_at`, `account_guard_ref`, `team_id`,
`app_id`, `bundle_id`, `platform`, `live_build`, and `internal_group_ids`.
Account mismatch exits nonzero before app discovery. Keep the executable
regular, executable, single-linked, and not group/world writable; the verifier
checks its pinned bytes before every run. Capture its first output as the Apple
observation used to prepare and reserve the request. Dispatch executes the same
pinned probe again and compares stable state while requiring a fresh timestamp.

Materialize the pending authorization into that directory, fill every
task/health/repository/resource/grant fact, change the decision to `approved`,
and finalize the same file against the approved schema. `--replace` is explicit;
it recomputes the installed contract ID/hash and never approves missing fields.

Materialize a fresh run-specific harness in the same directory (or copy the
reviewed host template), then set `run_authorization`, `run_ledger`, private
policy, coordinator binding, client roots, repository, and container to their
exact values. Re-run the skill-manifest observation after those fields are
final; do not reuse another run's harness hash.

Then run:

```sh
"$APE" materialize \
  --template '<installed-agent-harness>/templates/run-authorization.json' \
  --schema '<installed-agent-harness>/contracts/schemas/run-authorization.pending.schema.json' \
  --output '<run-root>/authorization.json'
# Populate and explicitly approve authorization.json after review.
"$APE" materialize \
  --template '<run-root>/authorization.json' \
  --schema '<installed-agent-harness>/contracts/schemas/run-authorization.schema.json' \
  --output '<run-root>/authorization.json' --replace
"$APE" initialize-run \
  --authorization '<run-root>/authorization.json' \
  --ledger '<run-root>/ledger.jsonl' --run-root '<run-root>' \
  --harness '<run-root>/private-harness.json' \
  --coordinator-state '<absolute-private-state-path>'
```

Every protected coordinator CLI operation supplies the private harness:

```sh
"$APE" resources '<absolute-private-state-path>' acquire \
  --harness '<absolute-private-harness-path>' \
  --authorization '<run-root>/authorization.json' --plan-id '<resource-plan-id>' \
  --resource '<resource>' --descriptor '<canonical-json>' \
  --run-id '<run-id>' --actor '<writer>' --ttl-seconds 300
```

Store only the returned exact `result` receipt as a private JSON file and record
it in the run ledger. Heartbeat before expiry,
never beyond the contract's bounded TTL, and replace the prior receipt with the
new one. Reverify the private harness binding and live receipt when reserving an
external action, then run `apple-verify verify-reservation` immediately adjacent
to the actual tool call. The fence is local ownership evidence; GitHub, Apple,
and Git remotes do not automatically enforce it.

Generate the action request from one approved grant plus the exact receipt,
descriptor, paths, and fresh health report. Derived GitHub targets use the exact
target established by the earlier successful external-write record. Apple
grants additionally provide private action/artifact and ASC observation files:

```sh
"$APE" prepare-action \
  --authorization '<run-root>/authorization.json' --grant-id '<grant-id>' \
  --receipt '<run-root>/receipt.json' \
  --resource-descriptor '<run-root>/descriptor.json' \
  --health-report '<run-root>/health.json' --target '<exact-target>' \
  --path '<affected-path>' --output '<run-root>/request.json' \
  --run-root '<run-root>'
```

Reserve that exact action into the ledger, then atomically claim it immediately
before dispatch. The claim permits invocation to start no later than 60 seconds
after revalidation and may be shorter when authority or lease expiry is nearer.
Long-running completion uses its approved async bound and a live heartbeat; the
60-second launch deadline is not a completion timeout. Both gates re-evaluate
the same exact health-report bytes and action-request digest. Git
commit/push/PR dispatch rechecks the reserved repository observation; Spec Kit
and Apple actions also re-read their selected live state:

```sh
"$APE" authorize --authorization '<run-root>/authorization.json' \
  --request '<run-root>/request.json' --ledger '<run-root>/ledger.jsonl' \
  --run-root '<run-root>' --policy-overlay '<private-policy.json>' \
  --authoritative-root '<repository-root>' --harness '<private-harness.json>' \
  --coordinator-state '<private-state.json>' \
  --health-report '<run-root>/health.json'
"$APE" verify-reservation --ledger '<run-root>/ledger.jsonl' \
  --reservation-id '<returned-reservation-id>' --run-root '<run-root>' \
  --harness '<private-harness.json>' --coordinator-state '<private-state.json>' \
  --health-report '<run-root>/health.json' --request '<run-root>/request.json'
```

Invoke the external tool only from the exact request and operation payload
returned by this adjacent verification. An Apple action blocks when the pinned
probe is missing, changed, stale, fails its private account guard, or reports
different stable app/build/group state.

A reservation is intentionally single-use even if the process crashes. After
an ambiguous crash, do not retry from the same reservation. Perform the
action-specific readback, record whether the target accepted the action, and
start a fresh authorization/run only when the observed state permits it.
The same burn-and-readback rule applies when a coordinator heartbeat, release,
or recovery was persisted but its response or corresponding ledger append was
lost. Never reconstruct a success timestamp or confirmation from memory.

## Trust boundary

This local harness coordinates cooperative Codex, Claude, and developer
processes running as the same logged-in user. Private JSON, file modes, hashes,
locks, and fencing prevent accidental drift, stale reuse, and normal concurrent
collisions; they are not a security boundary against a hostile same-user
process that can rewrite files or call `git`, `gh`, or `asc` directly. The
printed dispatch result is audit evidence, not a bearer credential enforced by
GitHub, Apple, or Git.

If adversarial isolation is required, place write credentials in a separate
trusted broker, accept only signed run authorizations, and have that broker
perform the exact one-shot operation and remote readback. Do not claim
cryptographic authorization or remote exactly-once delivery from this local
skill alone. Normal autonomous task-to-PR work remains valid after one explicit
approval because the selected agents are inside this cooperative boundary.

## Skill update

An updated coordinator or enforcement contract intentionally fails the old
executable/source binding. Do not auto-rehash it. First finish or safely recover all
active leases, review the installed change and state-schema compatibility,
observe the new `runtime-identity`, update the private harness, and
rerun health. If status cannot read
the old state, stop for an explicit migration decision; never replace it with a
fresh parallel coordinator to keep working.

## Recovery boundary

Expiry is not release. Recovery requires a different run's bounded read-only
observer to show that the owner and every outstanding child/tool process are
dead, the protected state is clean, and the live resource is revalidated. The
observer supplies its own trusted harness and active authorization through
`--observer-harness` and `--observer-authorization`; replacement ownership, if
requested, has another exact plan/authority tuple. The coordinator verifies
evidence shape, freshness, authority, digest binding, and fencing. Preserve the
underlying diagnostics and never infer death from lease expiry alone. Simulator
recovery follows bounded non-reboot diagnosis; reboot is neither an automatic
step nor a lease-recovery substitute.
