# app-store-connect

Manages **App Store Connect** operations through the **asc CLI** (https://asccli.sh).

You stop clicking through https://appstoreconnect.apple.com and start running one terminal command for whatever release task you need.

## What it does

- Walks you through installing asc and authenticating with an App Store Connect API key (one-time).
- Runs TestFlight uploads, App Store submissions, metadata updates, screenshot uploads, crash triage, certificate listing, Xcode Cloud triggers.
- Pre-flights every submission so you don't waste a 24-hour review cycle.
- Resolves numeric app IDs from bundle IDs once per turn — you don't have to remember them.
- Uses `--output json` when extracting fields, `--output table` for human summaries.
- Tells you the typical async wait for every op (build processing 5–30 min, App Store review ~24h) so you don't sit and poll.

## What it deliberately doesn't do

- Open App Store Connect in a browser — asc covers it.
- Submit for review without running `preflight` first.
- Auto-confirm `--confirm` submissions when you didn't explicitly say "submit."
- Rotate code signing certificates on your behalf (cert ops have downstream consequences; you run them).
- Sit in a tight poll loop on async ops — tells you what to recheck and when.

## When to use

- "Upload this IPA to TestFlight."
- "Distribute build 142 to the Internal group."
- "Submit version 1.2.3 for App Store review."
- "Update the en-US description and what's-new."
- "Show me TestFlight crashes from the last week."
- "List my provisioning profiles."

## Prerequisites

- An App Store Connect account with at least App Manager role.
- An App Store Connect **API key** (`.p8` file) — generated once at https://appstoreconnect.apple.com → Users and Access → Integrations → App Store Connect API.

## One-time install + auth

```bash
brew install asc
# or
curl -fsSL https://asccli.sh/install | bash

asc auth login \
  --name "MyApp" \
  --key-id "ABC123XYZ" \
  --issuer-id "57246542-...-..." \
  --private-key ~/.appstoreconnect/keys/AuthKey_ABC123XYZ.p8

asc auth current   # verify
```

The agent walks you through this on first use.

For CI: set `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY` env vars instead.

## Install

```bash
npx claude-plugins install @shawnbaek/agent-design/app-store-connect
```

Requires Claude Code v2.0.12+. Or interactively inside Claude Code:

```text
/plugin marketplace add shawnbaek/agent-design
/plugin install app-store-connect@indie-native-app
```

## References

- asc homepage → https://asccli.sh
- Install script → https://asccli.sh/install
- App Store Connect API → https://developer.apple.com/documentation/appstoreconnectapi
- Get an API key → https://appstoreconnect.apple.com → Users and Access → Integrations

## Companion agents in this marketplace

- [`xcodebuild`](../xcodebuild/README.md) — produces the IPA you upload here.
- [`screenshot`](../screenshot/README.md) — uploads screenshots through this agent's `asc screenshots upload`.
- [`apple-platform-ui`](../apple-platform-ui/README.md) — builds the UI that becomes the app you submit.
