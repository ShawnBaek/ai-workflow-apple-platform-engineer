# Secrets vs Variables — what goes where, via `gh` CLI

The rule:

- **Secrets** (`gh secret set`) — anything that, if leaked, lets someone act as you. App Store Connect API key, signing cert passwords, fastlane match passwords, webhook tokens.
- **Variables** (`gh variable set`) — public config. Bundle IDs, scheme names, App Store Connect numeric app IDs, simulator names, Xcode version.

Secrets are encrypted at rest, hidden from logs, never echoed in workflow output. Variables are visible in workflow logs and in the Settings UI. Use the right one — don't put a workspace name in a secret and don't put a private key in a variable.

## Sensitive — `gh secret set`

```bash
# App Store Connect API private key (.p8 file contents)
gh secret set ASC_PRIVATE_KEY < ~/.appstoreconnect/keys/AuthKey_ABC123XYZ.p8

# A long generated password (read from stdin)
gh secret set MATCH_PASSWORD --body "$(openssl rand -hex 32)"

# Apple ID app-specific password (if uploading via altool — prefer asc + API key)
gh secret set APPLE_ID_APP_PWD --body "xxxx-xxxx-xxxx-xxxx"

# CocoaPods Trunk token (if you publish a pod)
gh secret set COCOAPODS_TRUNK_TOKEN --body "Bearer ABC..."

# Sentry / Datadog / Bugsnag upload tokens
gh secret set SENTRY_AUTH_TOKEN --body "sntrys_..."
```

For an **environment-scoped** secret (different values per `development` / `staging` / `production`):

```bash
gh secret set ASC_PRIVATE_KEY --env production < AuthKey_PROD.p8
gh secret set ASC_PRIVATE_KEY --env staging    < AuthKey_STG.p8
```

Reference in workflows:
```yaml
env:
  ASC_PRIVATE_KEY: ${{ secrets.ASC_PRIVATE_KEY }}
```

For an environment-scoped workflow, add `environment: production` to the job — that unlocks the per-env secret.

## Non-sensitive — `gh variable set`

```bash
gh variable set APP_BUNDLE_ID      --body "com.example.notes"
gh variable set APP_SCHEME         --body "MyApp"
gh variable set APP_WORKSPACE      --body "MyApp.xcworkspace"
gh variable set ASC_APP_ID         --body "1234567890"        # numeric, from asc apps list
gh variable set ASC_KEY_ID         --body "ABC123XYZ"         # public — key identifier
gh variable set ASC_ISSUER_ID      --body "57246542-..."      # public — issuer UUID
gh variable set SIMULATOR_NAME     --body "iPhone 16"
gh variable set XCODE_VERSION      --body "16.0"
gh variable set MIN_DEPLOYMENT     --body "26.0"
```

Wait — **isn't `ASC_KEY_ID` and `ASC_ISSUER_ID` sensitive?** Apple says no. The key ID and issuer ID identify *which* key to use; the actual private key (`.p8`) is what authenticates. The pair without the `.p8` cannot make API calls. So both are variables, not secrets.

Reference in workflows:
```yaml
env:
  APP_SCHEME: ${{ vars.APP_SCHEME }}
  ASC_KEY_ID: ${{ vars.ASC_KEY_ID }}
```

## List, inspect, delete

```bash
# Secrets
gh secret list
gh secret list --env production
gh secret delete ASC_PRIVATE_KEY
gh secret delete ASC_PRIVATE_KEY --env staging

# Variables
gh variable list
gh variable list --env production
gh variable get APP_SCHEME             # prints value (variables are visible)
gh variable delete APP_SCHEME
```

You cannot `gh secret get` — secret values are write-only.

## Organization-wide vs repo-scoped

Pass `--org $ORG` to set at org scope (shared across all repos):

```bash
gh secret set ASC_PRIVATE_KEY --org acme-inc < AuthKey.p8
gh variable set ASC_ISSUER_ID --org acme-inc --body "uuid"
```

Limit visibility to specific repos with `--repos`:

```bash
gh secret set ASC_PRIVATE_KEY --org acme-inc \
  --repos acme-inc/notes-app,acme-inc/notes-widget < AuthKey.p8
```

## Pitfalls

- **Multi-line values via `--body` get mangled.** Use `< file` for anything multi-line (`.p8`, certificates, JSON blobs).
- **Trailing newlines**. `echo "X" | gh secret set FOO` appends `\n`. Use `printf "X" | gh secret set FOO` or `gh secret set FOO --body "X"`.
- **Don't `gh secret set` from a script that you commit**. The shell history may have the value. Use `--body-file` or `<file` so the secret never appears as a string in the command line.
- **Rotating secrets**: set the new value via `gh secret set` — it overwrites. No "version" concept. Workflows that start after the set use the new value; in-flight workflows finish with the old.

## What the cicd skill enforces

When the skill generates a workflow file, it:

1. Inspects every `env:` block.
2. For each variable, decides secret vs variable using the rule above.
3. Emits the `gh secret set` / `gh variable set` commands the developer needs to run **as a separate block** in the chat — not in the workflow file itself.
4. Reminds the developer to run those once before the first PR, and to re-run them when rotating credentials.
