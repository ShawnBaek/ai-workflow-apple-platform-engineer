# Self-hosted runner setup (macOS, via `gh` CLI)

Indie mobile devs need a Mac to build iOS — GitHub's hosted macOS runners are slow and expensive. A self-hosted runner on the developer's own Mac (or a dedicated Mac mini) is faster, free, and has the developer's Xcode + signing certificates already installed.

## Prerequisites

- A Mac running the latest macOS that the developer's app supports.
- **Xcode** installed via App Store (full, not just CLT). Confirm with `xcode-select -p` → `/Applications/Xcode.app/Contents/Developer`.
- **Homebrew** (`brew --version` works).
- **`gh` CLI** authenticated with the repo: `brew install gh && gh auth login`.
- Admin password (the runner installer asks for it once).

## Step 1 — Request a registration token

GitHub registration tokens expire in 1 hour. Get a fresh one immediately before running the config step.

```bash
gh api -X POST \
  repos/$OWNER/$REPO/actions/runners/registration-token \
  --jq .token
```

For an org-wide runner (one runner serving many repos):

```bash
gh api -X POST \
  orgs/$ORG/actions/runners/registration-token \
  --jq .token
```

## Step 2 — Download and configure the runner

Apple Silicon (M1/M2/M3/M4):

```bash
mkdir -p ~/actions-runner && cd ~/actions-runner
curl -fsSL -o runner.tar.gz \
  https://github.com/actions/runner/releases/download/v2.319.0/actions-runner-osx-arm64-2.319.0.tar.gz
tar xzf runner.tar.gz
./config.sh \
  --url https://github.com/$OWNER/$REPO \
  --token $TOKEN \
  --name "$(hostname)-runner" \
  --labels self-hosted,macOS,arm64,xcode \
  --work _work
```

Intel Mac: swap `osx-arm64` → `osx-x64` and `arm64` label → `x64`.

The `--labels` are how your workflow selects this runner. Use specific ones (`xcode-16`, `signing-mac`) for fleets with mixed setups; minimal ones (`self-hosted,macOS,arm64`) for a single dev's Mac.

## Step 3 — Run as a service (boots with the Mac)

```bash
cd ~/actions-runner
sudo ./svc.sh install $(whoami)
sudo ./svc.sh start
sudo ./svc.sh status    # verify
```

Without `svc.sh install`, you'd run `./run.sh` in a foreground terminal — fine for testing, useless after the dev closes their laptop.

## Step 4 — Verify on GitHub

```bash
gh api repos/$OWNER/$REPO/actions/runners --jq '.runners[] | {name, status, labels: [.labels[].name]}'
```

Look for `"status": "online"`. If `offline`, restart with `sudo ./svc.sh restart`.

## Maintenance

- **Update**: download new release, stop service, replace files, restart.
- **Remove**: get a removal token, then `./config.sh remove --token $TOKEN` then `sudo ./svc.sh uninstall`.
- **Logs**: `~/actions-runner/_diag/` — keep an eye on disk usage.

## Multi-runner on one Mac

Possible — put each runner in its own folder (`~/runner-app-A`, `~/runner-app-B`), give each a unique `--name`. They share the same Xcode + Homebrew but run jobs sequentially per runner (concurrent across runners). Useful when one Mac serves multiple apps.

## Security notes

- A self-hosted runner runs **whatever code lands in the workflow file**. Don't enable PRs from forks against a public repo, or restrict to "Require approval for all outside collaborators" in Settings → Actions → General.
- Don't share the runner across orgs unless you trust everyone in them.

## References

- GitHub: [Adding self-hosted runners](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/adding-self-hosted-runners)
- GitHub: [Configuring as a service (macOS)](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/configuring-the-self-hosted-runner-application-as-a-service)
