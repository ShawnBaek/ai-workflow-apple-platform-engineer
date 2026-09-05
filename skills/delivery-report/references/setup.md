# Private delivery-channel setup

Set `APE` to the built Swift verifier; see [setup](../../../docs/getting-started.md).

Choose one channel first. Telegram is the simplest unattended option; iMessage
Shortcuts suits a personal Mac; WhatsApp is appropriate only when its opt-in,
template, webhook, and possible-cost requirements are accepted.

## 1. Prepare the private configuration

1. Copy [channel-config.json](../templates/channel-config.json) to a private path
   outside the repository, such as `~/.config/ios-experts/delivery-report.json`.
2. Restrict that file to the current user (`chmod 600 <private-config>`). Store
   only aliases such as `owner`, `keychain.telegram.owner`, or
   `shortcuts.delivery-report-owner-text`.
3. Store real tokens and destination identifiers in macOS Keychain or another
   approved secret store. Do not paste them into an agent chat, repository,
   command transcript, PR, screenshot, or recording.
4. Add one channel entry with `send_policy: exact_task_authorization` and
   `media_policy: reviewed_allowlist_only`. Keep `enabled: false` until the
   channel-specific health check passes.
5. Render a local preview before any send:

   ```sh
   "$APE" delivery-report \
     <private-completion-report.json> --channel telegram
   ```

Changing the output format does not send anything. The formatter writes only to
stdout. Before an authorized send, compare the rendered output and media with
the channel's current limits. If it does not fit, create and authorize a new
shorter report hash; never silently truncate an already authorized report.
All channel formats are preview-only; WhatsApp preview text is not an approved
template and cannot replace one outside the service window.

## 2A. Telegram Bot API

1. Follow Telegram's [BotFather tutorial](https://core.telegram.org/bots/tutorial#obtain-your-bot-token),
   create a bot with `/newbot`, and place the token in Keychain. Telegram says
   to treat the token like a password.
2. The intended recipient opens the bot conversation and sends `/start`; a bot
   cannot begin that private conversation itself.
3. Run the private adapter's `getMe` health check without logging its tokenized
   request URL.
4. Inspect `getWebhookInfo`. Use `getUpdates` to resolve the intended chat only
   when no webhook is configured; the two update modes cannot operate together.
5. Store the resulting chat ID only behind `destination_ref`, then enable the
   channel.
6. With an exact send authorization, test `sendMessage`, then one reviewed
   `sendPhoto` and one reviewed `sendVideo`. Recheck current size and format
   limits in the [Bot API](https://core.telegram.org/bots/api) at send time.
7. Record `ok: true` and returned message ID as `accepted`. Telegram Bot API
   does not provide a general delivered/read receipt; require an explicit user
   acknowledgement if stronger evidence is essential.

## 2B. WhatsApp Cloud API

1. Use Meta's [Cloud API get-started guide](https://developers.facebook.com/documentation/business-messaging/whatsapp/get-started)
   to create or connect the app, WhatsApp Business Account, and test business
   number.
2. Send the official test template, configure the
   [messages webhook](https://developers.facebook.com/documentation/business-messaging/whatsapp/webhooks),
   and replace temporary credentials with an approved System User token.
3. Grant only the documented permissions required by the selected integration;
   store the token, WABA ID, phone-number ID, and recipient behind private refs.
4. Verify the business phone-number status is `CONNECTED`, the recipient opted
   in, and whether the 24-hour customer service window is open.
5. Inside an open window, use a service message. Outside it, require an
   `APPROVED` template and exact cost approval before sending because delivered
   templates can be billable. Recheck the live
   [pricing policy](https://developers.facebook.com/documentation/business-messaging/whatsapp/pricing).
6. Recheck live [media limits](https://developers.facebook.com/documentation/business-messaging/whatsapp/messages/media)
   before attaching one reviewed screenshot or trimmed video.
7. The send response is only `accepted`. Correlate its message ID with the
   [webhook status](https://developers.facebook.com/documentation/business-messaging/whatsapp/webhooks/reference/messages/status)
   before claiming `sent`, `delivered`, `read`, `failed`, or `played`; dedupe
   repeated webhook events.

## 2C. iMessage through Shortcuts

1. The user manually [sets up Messages on the Mac](https://support.apple.com/guide/messages/ichte16154fb/mac).
   The agent never handles the Apple Account password or verification code.
2. In Shortcuts, create `Delivery Report - owner - Text` and `Delivery Report -
   owner - Media`. Select the fixed recipient inside each Shortcut so the
   contact never appears in source or config.
3. Make the text Shortcut accept text input and the media Shortcut accept file
   input. Remove interactive “Ask Each Time” steps that would block unattended
   execution.
4. Run each Shortcut manually once and approve only the required privacy and
   Automation prompts.
5. Verify the aliases with `shortcuts list`. Apple's
   [command-line guide](https://support.apple.com/guide/shortcuts-mac/apd455c82f02/mac)
   documents `shortcuts run` and file input.
6. With exact send authorization, test the text Shortcut and then its media
   counterpart with reviewed allowlisted files. Do not invent undocumented
   media limits; retain the actual Messages error when a file fails.
7. Exit code zero proves local Shortcut completion only. If delivered/read is
   required, verify the corresponding indicator in Messages and label that
   observation as manual.

## 3. Authorize and verify each report

1. Save the exact preview bytes in a private file and calculate their digest:

   ```sh
   "$APE" delivery-report \
     <private-completion-report.json> --channel telegram > <private-report.txt>
   shasum -a 256 <private-report.txt>
   ```

2. Create a private JSON envelope matching
   [delivery-authorization.schema.json](../contracts/delivery-authorization.schema.json).
   Bind one channel/destination alias, preview SHA-256, reviewed screenshot or
   `trimmed_video` references and hashes, transport alias, issue/expiry times,
   run/authorization IDs, and a single-use idempotency key. WhatsApp also binds
   service-window versus approved-template mode. Template mode additionally
   binds the private template alias, language, exact cost approval, and SHA-256
   of the final canonical JSON request (UTF-8, sorted keys, no insignificant
   whitespace).
3. Validate the unchanged output against that envelope before the transport can
   consume it:

   ```sh
   "$APE" delivery-report \
     <private-completion-report.json> --channel telegram \
     --authorization <private-authorization.json> \
     --channel-id owner --destination-ref private.telegram.owner
   ```

A different report, recipient, media list, transport, time window, or format
blocks the send. The private transport must validate the same envelope, hash the
actual allowlisted media, and atomically consume the idempotency key.
For an approved WhatsApp template, it must also pass the canonical request hash
to the checker with `--whatsapp-request-sha256` and verify that the configured
`whatsapp_template_ref` equals the authorization before making the API call.

After the attempt, record text and media independently. If text is accepted but
media fails, report partial success; do not resend the text. Redact provider
responses before saving evidence and never publish the private configuration.
