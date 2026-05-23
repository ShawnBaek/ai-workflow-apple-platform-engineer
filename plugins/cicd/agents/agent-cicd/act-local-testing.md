# Test workflows locally with `act` before pushing

The fastest way to find a broken workflow file is **not** to commit, push, wait for the runner, fail, and tweak. It's to run the workflow on the developer's own Mac via [`act`](https://nektosact.com) first.

Reference: https://nektosact.com/usage/runners.html

## Install

```bash
brew install act
```

`act` itself runs in Docker by default for Linux-runners. We're targeting **self-hosted macOS** runners — so we tell `act` to skip Docker entirely and use the host Mac.

## The magic flag for self-hosted macOS

```bash
act -P macos-latest=-self-hosted
```

The trailing `-self-hosted` after the equals sign tells `act` "don't pull a Docker image for `macos-latest` — run the steps on the host directly." This is what makes `act` actually testable for Apple-platform workflows. From [nektos/act runners docs](https://nektosact.com/usage/runners.html):

> Using `-P <runs-on>=-self-hosted` will tell act to run the workflow on the host machine instead of in a container.

For workflows targeting the `[self-hosted, macOS, arm64, xcode]` label set, map that label too:

```bash
act -P self-hosted=-self-hosted
act -P "self-hosted=-self-hosted" -P "macOS=-self-hosted" -P "arm64=-self-hosted"
```

(Easiest: map every label your `runs-on` line uses.)

## Run a specific workflow / job

```bash
act push                                # all jobs triggered by `on: push`
act pull_request                        # all jobs triggered by `on: pull_request`
act -j build                            # just the `build` job
act -W .github/workflows/build-and-test.yml -j build   # specific file
```

`workflow_dispatch` triggers (manual ones like release) need:

```bash
act workflow_dispatch -W .github/workflows/release-testflight.yml \
  --input version=1.2.3 --input build=42
```

## Pass secrets and variables to `act`

`act` doesn't know about `gh secret set` / `gh variable set`. Mirror them to local files:

`~/.secrets` (gitignored):
```
ASC_PRIVATE_KEY="-----BEGIN PRIVATE KEY-----
...
-----END PRIVATE KEY-----"
```

`~/.vars`:
```
ASC_KEY_ID=ABC123XYZ
ASC_ISSUER_ID=uuid-here
APP_SCHEME=MyApp
APP_WORKSPACE=MyApp.xcworkspace
SIMULATOR_NAME=iPhone 16
ASC_APP_ID=1234567890
```

Then:
```bash
act -P self-hosted=-self-hosted \
    --secret-file ~/.secrets \
    --var-file ~/.vars
```

**Never commit these files.** Add to `.gitignore`:
```
.secrets
.vars
```

## The canonical local-test cycle

Before pushing a workflow change:

```bash
# 1. Dry-run — shows what would execute
act -P self-hosted=-self-hosted --dryrun

# 2. Real run, single job
act -P self-hosted=-self-hosted -j build --secret-file ~/.secrets --var-file ~/.vars

# 3. If green, commit + push + open PR
git add .github/workflows/build-and-test.yml
git commit -m "ci: add build-and-test workflow"
git push -u origin <branch>
gh pr create --fill
```

## Caveats

- **`act` on macOS host doesn't isolate**. It runs commands as your user. Don't run unfamiliar workflows. Read the YAML first.
- **`actions/setup-xcode@v1` and similar actions assume an Ubuntu container**. Skip them — your host already has Xcode. Comment them out for local `act` runs (or guard with `if: ${{ !env.ACT }}` so they no-op locally and run on GitHub).
- **`actions/checkout@v4`** works because `act` does a local clone of the working directory. Files are present.
- **Disk usage**: `act` puts artifacts in `/tmp/act-artifacts/`. Clean periodically.

## When `act` passes but GitHub fails

The differences are almost always:
1. **Tool version drift** — your Mac has Xcode 16, the runner has Xcode 15. Pin via `xcode-select` in the workflow.
2. **Missing Homebrew packages** on the runner that `act` had locally. Add a `brew list <pkg> || brew install <pkg>` guard at the top of the job.
3. **Path differences** — `~/actions-runner/_work` vs `$HOME` on local. Use `$GITHUB_WORKSPACE` consistently.
4. **Secret content differs** — your `~/.secrets` has the right `.p8` content; the GitHub secret was set wrong. Re-set via `gh secret set ASC_PRIVATE_KEY < AuthKey_X.p8`.

## References

- nektos/act docs → https://nektosact.com
- nektos/act runners (the `-self-hosted` flag) → https://nektosact.com/usage/runners.html
- GitHub Actions: testing workflows locally → https://docs.github.com/en/actions/use-cases-and-examples/testing-your-actions
