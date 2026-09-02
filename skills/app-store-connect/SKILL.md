---
name: app-store-connect
description: >-
  Safely handles App Store Connect and Xcode Cloud operations such as build upload, TestFlight distribution, metadata, screenshots, crash/feedback inspection, signing resources, and App Store submission. Use when the developer mentions App Store Connect, TestFlight, asc, IPA/PKG upload, provisioning, store metadata, review submission, Xcode Cloud, or release status. Enforces the project's private Apple account/team boundary and separates read, upload, distribute, and submit approvals. Do not use for Apple Ads campaigns or paid keywords; use apple-ads.
---

# App Store Connect

Use the project's approved App Store Connect client (for example `asc`) only
after resolving the private Apple account/team guard. CLI availability or cached
authentication never authorizes reading another account.

## Account gate comes first

1. Load the expected team/account/provider/profile from the private project
   policy. Reusable public skills must not contain personal identifiers.
2. Inspect only local authentication metadata needed to compare the active
   profile. Redact key IDs/issuer identifiers when reporting.
3. If the resolved identity differs or cannot be constrained to the expected
   account, stop before listing apps/builds or changing anything.
4. Resolve the exact app numeric ID, bundle ID, platform, version, and intended
   action after the account matches.
5. Record the client version and supported command syntax from live `--help`;
   third-party CLI surfaces can change.

Never ask the user to paste a private key, password, OTP, or recovery code into
chat. Install/login/key creation and scope expansion are separate approved setup
tasks, not automatic first-run steps.

## Separate authority by action

Do not collapse these into a single “release” permission:

- read status/builds/crashes/feedback;
- upload a built artifact;
- distribute to a named TestFlight group;
- change tester notes or store metadata;
- upload/replace screenshots;
- create/change bundle IDs, capabilities, certificates, or profiles;
- trigger an Xcode Cloud workflow;
- run submission preflight;
- submit for App Review.

The user's request must cover the exact external mutation. Submission and
certificate/profile changes always use their own final gate. Never infer submit
authority from “upload,” “release prep,” or a green build.

When the user explicitly selects an unattended TestFlight delivery target, read
[`references/unattended-testflight-delivery.md`](references/unattended-testflight-delivery.md).
An immutable, unexpired single-use grant may authorize upload, a bounded
processing wait, and exact named internal-group distribution without another
routine prompt. This is not arbitrary auto-confirm: any target, account,
artifact, group, compliance, signing, or permission drift blocks the run.

## Operating flow

1. Use `app-versioning` to verify marketing/build values at their source of
   truth and in the built bundle.
2. Use `xcodebuild` in the authoritative host project to archive/export and
   verify signing identity, entitlements, platform, and artifact hash.
3. Run the smallest supported App Store Connect operation with explicit app and
   account/profile flags where available.
4. Prefer structured output for identifiers/state; do not parse a decorative
   table for automation.
5. Observe async state with bounded polling or a product wait/monitor mechanism.
   Do not tight-loop.
6. Read back the exact changed object and record its stable ID/state. A successful
   request without post-observation is not completion.

For screenshots, route capture/privacy/spec verification through `screenshot`.
For CI credentials and protected environments, use `cicd`.
For Apple Ads campaigns, paid keywords, bids, budgets, attribution, or reporting,
route through `apple-ads`. App Store metadata keywords and paid Apple Ads keywords
are different surfaces with separate account guards and mutation approvals.
For StoreKit Testing, Sandbox Apple Accounts, sandbox purchases, subscription
renewal/expiry, billing failures, refunds, and transaction evidence, route the
test workflow through `storekit-sandbox-testing`; return here only for the exact
account-guarded App Store Connect read or mutation it requires.

## Preflight and evidence

Before upload/distribution/submission, require the relevant build/test evidence,
current agreement/compliance state, version/build association, localization and
screenshot completeness, encryption/export answers, privacy metadata, and
signing/entitlement checks appropriate to the app. Do not fabricate missing
answers.

Evidence should contain app/build/version IDs, platform, artifact hash, requested
action, pre/post state, client version, timestamp, and sanitized response. Never
store credentials or full account listings.

## Partial and async outcomes

Upload processing, TestFlight review, Xcode Cloud, and App Review are
asynchronous. Report `submitted/pending/processing` rather than `done` until
the requested terminal state is observed. If metadata or Project-board work
fails after a valid upload/PR, record partial success; do not roll back unrelated
successful external state automatically.

## Never

- read or mutate an account that does not match the private guard;
- switch to another cached profile or broaden credentials after 401/403;
- put secrets in command arguments, logs, PRs, artifacts, or RAG;
- auto-confirm submission or arbitrary distribution, certificate/profile
  rotation, or capability changes; exact pre-authorized internal TestFlight
  distribution follows the separate bounded continuation;
- archive from another checkout/container or regenerate XcodeGen implicitly;
- treat upload as submission or processing as approval;
- auto-merge source changes after a release operation.

References:

- [App Store Connect API](https://developer.apple.com/documentation/appstoreconnectapi)
- [Preparing an app for distribution](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution)
- [App Store Connect Help](https://developer.apple.com/help/app-store-connect/)
