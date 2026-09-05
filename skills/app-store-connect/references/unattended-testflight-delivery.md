# Pre-authorized unattended TestFlight delivery

Use this path only when the accepted run authorization selects
`testflight_uploaded` or `testflight_distributed`. Load the private Apple
account/team guard first and follow `agent-harness`'s
`contracts/testflight-workflow.json` continuation after `pr_ready`.

## Required binding

The initial immutable authorization must bind the exact:

- repository/base/branch, accepted Spec Kit identity when enabled, allowed paths,
  and the policy that the archive must be freshly derived from the reviewed PR
  commit;
- Apple account guard and team ID;
- numeric app ID, bundle ID, platform, marketing-version policy, and build-number
  policy;
- upload, bounded processing wait, and read-back grants;
- internal TestFlight group IDs when distribution is selected;
- expiry, attempt/wait limits, single-use grant IDs, and idempotency keys.

The archive hash cannot be known before implementation. After `pr_ready`, record
the reviewed patch/remote commit and the newly derived archive hash as linked,
schema-valid continuation evidence. The authorization gate checks that evidence
and a fresh guarded read-only ASC observation immediately before each Apple
action. This does not rewrite the original authorization.

Before every Apple action, re-evaluate the current request with
`apple-verify authorize`. A cached login, Xcode selection,
profile name, environment variable, or previous successful run cannot override
an account mismatch.

## Green path

1. Pass the selected `apple-development-health` profile without repairing or
   expanding access.
2. Reverify PR-ready source evidence and create a fresh archive from the exact
   authoritative container/commit.
3. Verify archive platform, bundle/version/build, signing identity, entitlements,
   export, and artifact hash.
4. Atomically reserve, then consume the exact upload grant once; preserve the request ID/response and
   read back the uploaded build.
5. Wait only within the approved async bound. `accepted`, `pending`, and
   `processing` are not completion.
6. For `testflight_uploaded`, stop after the approved processed/read-back state.
7. For `testflight_distributed`, acquire a new scoped lease, match only an
   approved internal group ID, consume the distribution grant, and read back
   the build/group association.
8. Publish sanitized evidence with its own phase-scoped grant and release every
   lease through the `finally` cleanup contract. Schema v1 permits at most one
   exact internal group per run; use a newly approved run for another group.

## Block instead of improvising

Stop when an account/app/group/artifact/authorization field drifts; a grant is
expired or consumed; required checks fail; processing exceeds the bound; or a
new agreement, compliance, encryption, privacy, signing, certificate, profile,
capability, external beta review, or credential decision is required.

Do not switch profiles, invent answers, rotate signing, distribute to a similar
group, submit for App Review, release to production, merge the PR, or clean the
machine. Exact preauthorization removes routine prompts only from the unchanged
green path; it does not broaden authority.
