---
name: delivery-report
description: >-
  Formats an Apple-development completion report and, only when privately configured and exactly authorized, delivers its PRs, checks, screenshots, trimmed recordings, omissions, and provider-reported usage through Telegram, WhatsApp, or iMessage Shortcuts. Use for end-of-task summaries or delivery-channel setup.
---

# Delivery Report

Turn one validated `agent-harness/templates/completion-report.json` instance
into a short, portable report. Formatting is read-only. An external message is
a separate mutation with its own authority and receipt evidence.

## Preview-first flow

1. Validate the completion report and its provider/client usage attribution.
2. Render the selected preview format to stdout with `apple-verify delivery-report`.
   Every `--channel` mode is preview-only and never invokes a transport.
3. Confirm that every screenshot is reviewed and every recording is
   `trimmed_video`, never a raw recording.
4. Load a private channel configuration and run only its read-only health
   check. Public files contain aliases, never credentials or recipient IDs.
5. Stop at the preview unless an exact task authorization is active. Config
   alone is not authority.
6. Instantiate `contracts/delivery-authorization.schema.json`, then make the
   formatter verify `channel_id`, `destination_ref`, `report_sha256`,
   `media_allowlist`, `transport_ref`, expiry, and `idempotency_key`.
7. The private transport rechecks the same envelope and actual media hashes,
   plus any WhatsApp template alias, language, and canonical request hash, then
   sends the unchanged bytes once. An uncertain response blocks
   blind retry; inspect the provider state using the same idempotency identity.
8. Record API `accepted`, transport execution, and `delivered/read` as distinct
   states. Never promote a weaker observation into a stronger claim.

An interactive approval or a finite pre-authorized delivery run may supply the
exact task authorization. An enabled channel, prior successful send, or approval
for PR/TestFlight work does not supply it. Never fan out to every configured
channel by default.

## Report contents

Include task/status, changes, phase PR links, minimum-sufficient checks,
screenshots, trimmed videos, omissions/residual risk, and provider/client-reported
token and cost status. Preserve `not_exposed`; never estimate tokens from text.
Do not attach Home, launch, splash, waiting, or raw recordings unless startup is
the acceptance target.

## Channel boundaries

| Channel | Safe transport | Strongest automated claim |
|---|---|---|
| Telegram | Bot API with private token/chat alias | API accepted with message ID |
| WhatsApp | Cloud API with opt-in/window/template checks | matching webhook status |
| iMessage | named Shortcuts on the signed-in Mac | local Shortcut completed |

iMessage has no public server API for this workflow. A local Shortcut exit code
does not prove delivery or reading. WhatsApp proactive messages outside the
24-hour customer service window require an approved template and separate cost
approval when charges may apply.

Read [setup.md](references/setup.md) before enabling a channel. Use
`templates/channel-config.json` only as a public-safe starting point and keep the
instantiated file outside the repository with owner-only permissions.

## Never

- request or print tokens, phone numbers, chat IDs, contact identifiers, or
  webhook payload identities;
- treat configuration as approval or choose a fallback recipient;
- send unreviewed media, a raw screen recording, or an expired evidence link;
- claim Telegram acceptance or Shortcut success as delivered/read;
- retry an ambiguous external write with a new idempotency key.
