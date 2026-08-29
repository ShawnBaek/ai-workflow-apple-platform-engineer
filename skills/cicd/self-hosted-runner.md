# Self-hosted macOS runner

A dedicated self-hosted Mac can provide a controlled Xcode version, local
hardware, and predictable queueing. A developer's daily-use Mac is higher risk:
workflow code runs with that user's filesystem and network access. Compare it
with GitHub-hosted macOS before choosing.

## Before registration

1. Verify the exact GitHub account, repository/organization, and private project
   policy. Do not register against a convenient cached login.
2. Decide whether fork/outside-collaborator code can ever reach the runner.
   Public untrusted PR code must not run with secrets or write access.
3. Dedicate an OS user and runner directory when practical. Do not reuse a user
   that holds broad Apple/GitHub credentials.
4. Record architecture, macOS, Xcode build, available disk, labels, signing
   access, and concurrency policy.
5. Retrieve the current download/configuration commands from the repository's
   GitHub Settings > Actions > Runners page. Do not paste a hardcoded runner
   release URL from an old guide.

Registration/removal tokens are short-lived credentials. Request them only when
the user approved registration/removal, do not print/store them, and run the
current GitHub-provided command in the intended runner directory.

## Labels and routing

Use labels that state actual capabilities, for example architecture, Xcode build,
and whether signing is present. A job must not select a generic runner and then
silently change Xcode or install tools. Limit each runner service to the
concurrency it can safely support; separate build tuple, Simulator/device, and
signing leases still apply across local agents and CI.

## Service and verification

After following GitHub's current macOS service instructions:

- verify the runner appears online for the exact repository/account;
- run a read-only diagnostic job that prints runner architecture and Xcode build;
- confirm the job lacks unneeded write permissions and secrets;
- verify logs/artifacts do not expose home paths or account material;
- test shutdown/restart and document who owns maintenance.

Do not run an application build until the Xcode project/account/host preflight is
complete.

## Security and maintenance

- Never execute untrusted fork code in a privileged workflow.
- Keep runner software and macOS/Xcode updates intentional and recorded.
- Use least-privilege repository/environment secrets and protected environments.
- Monitor disk with `xcode-storage`; never schedule blanket cache/Simulator/
  archive/workspace deletion.
- Remove a runner through GitHub's current removal flow. Do not delete its
  directory first and leave a registered orphan.
- Treat a shared runner's unexpected dirty workspace or active process as a
  blocked lease, not permission to wipe it.

References:

- [Adding self-hosted runners](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/adding-self-hosted-runners)
- [Configuring the runner as a macOS service](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/configuring-the-self-hosted-runner-application-as-a-service)
- [Self-hosted runner security](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions#hardening-for-self-hosted-runners)
