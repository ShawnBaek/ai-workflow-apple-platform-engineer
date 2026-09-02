---
name: storekit-sandbox-testing
description: >-
  Sets up, exercises, diagnoses, and verifies Apple In-App Purchase flows with StoreKit Testing in Xcode, App Store sandbox accounts, or TestFlight sandbox builds. Use for sandbox purchases, subscription renewals or expiry, billing retry, refunds, restores, offer eligibility, missing products, or sandbox transaction evidence. Do not use it as proof of production purchase readiness or as authorization to submit an app.
---

# StoreKit Sandbox Testing

Prove the purchase contract in the intended Apple test environment without
charging a real account or confusing local StoreKit simulation with App Store
sandbox evidence.

## Resolve the boundary first

1. Use `xcode-project-workflow` to resolve the exact checkout, first-opened
   Xcode container, scheme, configuration, destination, bundle ID, and signing
   team. Run Xcode, StoreKit, and Simulator tools only in the logged-in host
   environment.
2. Load the project's private Apple account/team policy before any App Store
   Connect or sandbox-account discovery. A cached Xcode team, CLI profile, or
   Sandbox Apple Account never overrides that guard.
3. Record the exact product IDs, product types, subscription group, intended
   storefront, and scenarios. Do not infer identifiers or prices from visible
   fallback copy in the app.
4. Select one environment from
   [the environment and scenario matrix](references/environment-and-scenarios.md):
   local StoreKit Testing, a development-signed App Store sandbox build, or
   TestFlight sandbox. State the selection before changing settings or buying.
5. Before a Sandbox Apple Account mutation, confirm the operator has one of
   Apple's permitted roles: Account Holder, Admin, App Manager, or Developer.
   Record the tester label, not its email address, and obtain approval for the
   exact tester and setting change.

## Protect a daily-use device and shared tester

Before installing on a daily-use iPhone or iPad, inspect the installed app:
production App Store, TestFlight, development, or none. A test build with the
same bundle ID can replace or migrate the app's container, Keychain items, and
App Group state. Prefer a dedicated test device. Otherwise obtain explicit risk
acknowledgement and a developer-confirmed backup/recovery plan before install;
never uninstall the app or delete device data as a reset procedure.

Prefer a dedicated Sandbox Apple Account for mutable scenarios. Clearing its
purchase history permanently removes **all** of that tester's sandbox purchases.
"Allow Purchases & Renewals" affects every device and active subscription using
that Sandbox Apple Account, not just this app or this device. Do not change it
on a shared tester without explicit approval and a restoration plan.

## Keep the environments distinct

- **StoreKit Testing in Xcode** uses a selected `.storekit` configuration and
  Xcode-signed transactions. It can run offline and does not prove that App
  Store Connect products, Apple-signed JWS transactions, or server
  notifications are configured correctly.
- **App Store sandbox** uses real product information from App Store Connect
  and Apple sandbox infrastructure. A development-signed app does not require
  an uploaded binary, but the Paid Applications Agreement, product metadata,
  matching bundle ID/team, and a Sandbox Apple Account must be ready.
- **TestFlight** always performs purchases in sandbox. The production Apple
  Account downloads the beta; a Sandbox Apple Account is needed only when the
  test requires the on-device sandbox controls.

Accessing those TestFlight sandbox controls may require signing out of the
device's production Media & Purchases account and then signing in to the
Sandbox Apple Account under Developer settings. Warn that this can temporarily
affect access to production purchases, and prefer a dedicated test device when
practical. Never sign the user out without immediate approval.

Before claiming a development-signed sandbox run from Xcode, inspect the Run
scheme. If a StoreKit configuration is active, that run uses Xcode's local test
environment, not App Store sandbox. Select `None` only when the user authorized
that project or scheme change. TestFlight builds use sandbox independently of
the local Run scheme.

## Prepare App Store sandbox

Use `app-store-connect` for account-guarded App Store Connect reads or writes.
Verify the following before pressing a purchase button:

- the Developer Program membership and Paid Applications Agreement are active;
- each product has the exact ID and type expected by the app, plus the minimum
  required reference name, localization, and price;
- the app bundle ID and signing team match the guarded App Store Connect app;
- the Sandbox Apple Account belongs to the same Developer Program account and
  uses an email address that has never been an Apple Account;
- the device is in Developer Mode when the selected platform requires it;
- the app receives the expected products from StoreKit, including identifier,
  type, display price, subscription group, and offer metadata relevant to the
  scenario.

Creating a sandbox tester, changing its storefront or renewal speed, enabling
interrupted purchases, disabling purchases and renewals, or clearing purchase
history mutates external test state. Obtain approval for the exact tester and
change immediately before it. Clearing purchase history is irreversible for
that tester; never use it as a generic retry step.

Never request, paste, log, screenshot, or store a Sandbox Apple Account
password, verification code, or recovery information. Let the developer enter
credentials in Apple's sign-in UI, or use an already-authorized signed-in test
account after confirming its non-sensitive identity and team scope.

## Exercise one bounded scenario

Before confirming Apple's sandbox payment sheet, restate the environment,
bundle ID, product ID, product type, test account label, and expected state
transition. One scenario approval does not authorize unrelated products,
tester-history deletion, refunds, or App Store Connect changes.

For a successful purchase:

1. Observe the entitlement state before purchase.
2. Fetch the exact product from StoreKit and preserve sanitized product
   evidence. A rendered price card alone is insufficient.
3. Confirm the payment sheet identifies the sandbox environment. Stop if it is
   production or the environment is ambiguous.
4. Complete the transaction and require successful StoreKit verification.
   Distinguish verified, unverified, pending, user-cancelled, and thrown-error
   outcomes.
5. Confirm the app calls `finish()` only after granting or durably recording the
   purchased content as its architecture requires.
6. Read the entitlement back from `Transaction.currentEntitlements`, the
   subscription status API, or the app's verified source of truth. Relaunch and
   verify that access survives without relying only on transient UI state.
7. When the app has a server, verify the transaction in the sandbox App Store
   Server API or sandbox notification pipeline. Record the endpoint,
   notification version, expected event, JWS verification result, and the
   transaction or original-transaction identifier used to correlate the
   client and server evidence. A generic test notification proves endpoint
   delivery only; it does not prove that the purchase generated the expected
   transaction event.

Also verify that a transaction initiated outside the app reaches the long-lived
`Transaction.updates` listener when that behavior is in scope. Start the
listener early enough that launch-time and cross-device events cannot be lost.

For subscriptions, start with the exact purchase and active-entitlement
scenario the user authorized. Add renewal, expiry, disabled auto-renew,
introductory or promotional eligibility, upgrade/downgrade, billing retry/grace
period, refund/revocation, interrupted purchase, Family Sharing, or storefront
changes only when separately selected. Before a refund test, choose declined,
approved full, or approved prorated behavior and state the expected entitlement
and server notification outcome. For an approved refund, verify the resulting
`revocationDate` and `revocationReason` on the transaction/entitlement and the
corresponding App Store Server Notification; a refund request alone is not proof
of revoked access. Sandbox renewal speed also changes billing-retry and
grace-period timing; record the tester's selected rate rather than assuming a
duration.

Billing-failure controls require iOS or iPadOS 16 or later. Write a phase/state
plan first: purchase successfully while purchases and renewals are enabled,
then disable them before the next renewal, verify the expected retry and grace
state, re-enable them, and verify recovery. Do not rely on a UI toggle or elapsed
time alone as evidence for any phase transition.

Do not add `StoreKitTest` tests or a `.storekit` file unless the user asks for
test code or local StoreKit configuration. Route requested automated coverage
to `apple-platform-testing` and keep it separate from the end-to-end sandbox
run.

## Diagnose without blind resets

When products are missing or disabled, check in this order:

1. the claimed environment; for an Xcode-launched build, inspect any active
   `.storekit` scheme configuration, but do not treat the local Run scheme as
   a cause for an installed TestFlight build;
2. exact product IDs and product types in source and App Store Connect;
3. guarded team, bundle ID, app record, agreements, localization, and price;
4. product availability/storefront and subscription-group configuration;
5. App Store Connect propagation time; product metadata changes can take time
   to appear in sandbox;
6. Sandbox Apple Account ownership, sign-in state, storefront activation, and
   device Developer Mode;
7. StoreKit error and verification result, followed by server environment and
   notification delivery when applicable.

Do not clear purchase history, create another tester, switch Apple accounts,
change product IDs, or edit the scheme until evidence identifies that layer.
Treat an App Store service outage or account mismatch as a blocked external
dependency, not an app regression.

After an authorized history clear, wait for Apple's change to propagate and
read back an empty purchase history plus the intended fresh-purchase or offer
eligibility state. Refresh the account/device cache only through Apple's
documented sign-out/sign-in path when needed; do not delete the app or device
data to force a reset.

## Evidence and completion

Report:

- repository/container, Xcode and OS version, device, scheme, and whether a
  `.storekit` configuration was active;
- guarded team match without exposing private credentials;
- bundle ID, product IDs/types, storefront, build origin, and sandbox-account
  label;
- sanitized product response and transaction environment/verification result;
- entitlement before purchase, immediately after, after relaunch, and after
  each selected renewal/expiry/refund state;
- server API or notification read-back when the app has a server;
- the approved phase/state plan and final read-back showing the tester's renewal
  speed, interrupted-purchase setting, purchases-and-renewals setting, Sandbox
  and Media & Purchases sign-in state, and intended installed app build were
  restored (or explicitly retained with approval);
- screenshots or hierarchy evidence for user-visible states, plus omitted
  scenarios and remaining risk.

A successful payment sheet, a passing build, a screenshot of premium UI, or a
locally signed Xcode transaction is not by itself end-to-end sandbox proof.
Stop before production purchase, upload, TestFlight distribution, metadata
mutation, or App Review submission unless the user separately authorizes that
exact action through its owning skill.

## Official sources

- [Testing at all stages with Xcode and sandbox](https://developer.apple.com/documentation/storekit/testing-at-all-stages-of-development-with-xcode-and-the-sandbox)
- [Testing In-App Purchases with sandbox](https://developer.apple.com/documentation/storekit/testing-in-app-purchases-with-sandbox)
- [Setting up StoreKit Testing in Xcode](https://developer.apple.com/documentation/xcode/setting-up-storekit-testing-in-xcode)
- [Create a Sandbox Apple Account](https://developer.apple.com/help/app-store-connect/test-in-app-purchases/create-a-sandbox-apple-account)
- [Manage Sandbox Apple Account settings](https://developer.apple.com/help/app-store-connect/test-in-app-purchases/manage-sandbox-apple-account-settings/)
- [Testing purchases made outside your app](https://developer.apple.com/documentation/storekit/testing-purchases-made-outside-your-app)
- [Testing refund requests](https://developer.apple.com/documentation/storekit/testing-refund-requests)
- [Testing App Store Server Notifications](https://developer.apple.com/documentation/storekit/testing-app-store-server-notifications)
- [App Store Server API sandbox](https://developer.apple.com/documentation/appstoreserverapi)
