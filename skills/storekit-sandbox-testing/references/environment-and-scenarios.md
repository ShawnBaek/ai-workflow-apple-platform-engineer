# StoreKit test environment and scenario matrix

Read this reference after the product IDs and requested test outcome are known.
Choose the smallest environment that proves the intended contract, then add a
later environment only for evidence the first one cannot provide.

## Environment matrix

| Environment | Product source | Transaction signature | App Store Connect required | Server-to-server proof | Best use |
| --- | --- | --- | --- | --- | --- |
| StoreKit Testing in Xcode | Local or synced `.storekit` file selected in the Run scheme | Xcode test environment | No for local data; optional for synced data | No Apple sandbox notification proof | Early UI, entitlement logic, deterministic failure states, Simulator/device debugging |
| Development-signed App Store sandbox | App Store Connect | Apple sandbox | Yes | Yes | End-to-end product lookup, Apple-signed transactions, sandbox server API and notifications |
| TestFlight | App Store Connect | Apple sandbox | Yes, including uploaded beta | Yes | Beta-build integration and tester experience |
| Production App Store | App Store Connect | Apple production | Yes | Yes | Real customer behavior; never a substitute for an authorized sandbox test |

When a `.storekit` file is active, StoreKit does not fetch the App Store
Connect sandbox products for that run. Set the scheme's StoreKit Configuration
to `None` before an App Store sandbox run, but only with authorization to change
the scheme or Xcode project state.

## Minimum scenario selection

### Every product

- product fetch returns the exact ID and expected product type;
- display name and localized price come from StoreKit, not hard-coded fallback
  text;
- verified purchase grants the intended entitlement once;
- pending, cancelled, unverified, and thrown-error results do not grant access;
- relaunch reconstructs access from verified StoreKit state;
- restore behavior matches the product type;
- the app does not finish a transaction before durable fulfillment.

### Consumable

- quantity or balance increments exactly once;
- redelivery cannot duplicate fulfillment;
- restore UI does not promise restoration Apple doesn't provide for
  consumables;
- server or local persistence survives interruption between fulfillment and
  `finish()`.

### Non-consumable

- repurchase is prevented or resolves as already owned;
- restore and cross-device entitlement work;
- refund or revocation removes access according to the product contract;
- Family Sharing is tested when enabled in App Store Connect.

### Auto-renewable subscription

- initial purchase, active status, relaunch, and restored entitlement;
- renewal, disabled auto-renew, and expiry only when those states are selected;
- introductory-offer eligibility and one-offer-per-subscription-group behavior
  when an intro offer exists;
- upgrade, downgrade, or cross-grade only when multiple levels are sold;
- billing retry and Billing Grace Period only when the app uses those states;
- declined, approved full, or approved prorated refund behavior only when
  selected, with the expected entitlement and server-notification result stated
  in advance;
- selected sandbox renewal speed and the resulting retry/grace timing recorded
  in evidence.

Sandbox subscriptions renew at accelerated rates and stop auto-renewing after
Apple's bounded number of renewals. Never translate a sandbox timestamp into a
production renewal promise.

### Non-renewing subscription

- purchase and app-managed expiration;
- repurchase behavior;
- restore or server reconstruction according to the app's own contract.

## Optional scenarios

Add only when applicable:

- interrupted purchase requiring action outside the app;
- disabled purchases and renewals for payment-failure behavior;
- Ask to Buy deferred state;
- promotional, offer-code, or win-back redemption;
- purchase initiated outside the app and delivered by `Transaction.updates`;
- refund request declined, approved full, or approved prorated;
- storefront change and region-specific availability;
- Sandbox Test Family and Family Sharing;
- App Store Server Notifications V2 and App Store Server API read-back.

## Mutable-scenario safety contract

Before changing a Sandbox account, record a compact state plan:

| Phase | Required state and evidence |
| --- | --- |
| Baseline | Tester label, permitted App Store Connect role, device OS, installed build origin/version, Sandbox and Media & Purchases sign-in state, renewal speed, interrupted-purchase setting, and purchases-and-renewals setting. |
| Exercise | Product, expected entitlement, selected external mutation, expected client transaction state, and expected server event. |
| Restore | Original or explicitly approved final tester settings and intended installed build, each read back after the scenario. |

On a daily-use device, inspect whether the installed build is production, TestFlight,
development, or absent before installing a same-bundle test build. That installation
can replace or migrate app data, Keychain data, or App Group state. Prefer a
dedicated device; otherwise require explicit risk acknowledgement and a backup or
recovery plan. Never uninstall the app or delete device data as a reset.

Sandbox tester mutations require Account Holder, Admin, App Manager, or Developer
access in App Store Connect. Use a dedicated tester for changes that can affect its
whole history or every signed-in device. In particular:

- clearing history irreversibly deletes all sandbox purchases for that tester;
- disabling "Allow Purchases & Renewals" affects all of that tester's active
  subscriptions and devices, rather than one app/device;
- changing renewal speed changes the billing-retry and grace-period timing;
- interrupted purchases continue until disabled or the tester resolves the
  required action on-device.

After a history clear, wait for propagation, read back empty history, verify the
intended fresh-purchase or offer-eligibility state, and refresh the account cache
only with Apple's documented sign-out/sign-in flow when required. Do not erase
the app or device data to force a cache reset.

### Billing retry and grace period

The "Allow Purchases & Renewals" control for sandbox billing-failure tests
requires iOS or iPadOS 16 or later. Use this ordered, observable plan:

1. With the setting enabled, complete and verify the initial purchase.
2. Disable it before the selected renewal; verify the retry and, if configured,
   grace-period state using entitlement/status and server evidence.
3. Re-enable it; verify recovery rather than assuming the next timestamp proves it.
4. Restore and read back the tester's final renewal speed and failure-control state.

### Refund and revocation

For an authorized sandbox refund request, define declined, approved full, or
approved prorated before sending it. Verify the actual outcome:
entitlement/access, transaction `revocationDate`, `revocationReason`, and the
matching App Store Server Notification. A submitted refund request or a refreshed
paywall is not evidence that revocation occurred.

## Controlled reset rules

Prefer a fresh dedicated tester or a deliberately selected scenario over
resetting shared state. Clearing Sandbox purchase history is irreversible for
the tester and may take time to propagate. Obtain exact approval, record the
tester label and prior state, clear only that tester, then sign out and back in
if Apple's current instructions require cache refresh.

Never delete a tester, clear its history, change its storefront, or toggle
purchase failures merely because a transaction did not produce the expected
UI. Diagnose the environment, account, product, verification, and entitlement
layers first.
