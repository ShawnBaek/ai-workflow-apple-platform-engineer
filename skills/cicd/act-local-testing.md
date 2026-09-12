# Validate workflows before push

No local tool perfectly reproduces a GitHub-hosted macOS image, a self-hosted
runner service, Xcode, signing, Simulator state, repository permissions, or
GitHub event context. Split validation by what it can prove.

## Static and local checks

Before push:

1. parse/lint the YAML with an approved pinned tool;
2. inspect `permissions`, events, concurrency, timeout, runner labels, and
   untrusted-code boundaries;
3. verify referenced scripts locally with safe test inputs;
4. check secret/variable names without reading or printing their values;
5. review the diff and expected artifact paths;
6. run Xcode commands only through the logged-in host workflow required by
   `xcode-project-workflow`.

`act` is useful for compatible Linux/container helper jobs and event-shape
checks. It is not macOS/Xcode evidence. Do not map a workflow to host execution
merely to make `act` run Apple commands; that runs workflow code as the logged-in
user without the isolation or service context of GitHub Actions.

## Safe `act` use

Use it only after reading the workflow and only for a compatible job that needs
no Apple signing/account credentials:

```sh
act pull_request -W .github/workflows/validate.yml -j validate --dryrun
act pull_request -W .github/workflows/validate.yml -j validate
```

Do not feed production secrets, private keys, profiles, or broadly scoped tokens
to local workflow emulation. Do not treat an `act` pass as proof that a macOS
runner, Xcode destination, or GitHub permission will pass.

## Final pre-PR smoke

For changed Apple build commands, use the actual approved Mac runner or logged-in
host environment on the affected smallest tuple. Record runner label, Xcode
build, package fingerprint, destination, command, exit result, and artifacts.

A workflow can still differ on GitHub because of event permissions, environment
protection, network access, runner labels, case-sensitive paths, or missing
configuration. Keep the first remote run observable and do not auto-merge it.

References:

- [nektos/act](https://nektosact.com/)
- [GitHub Actions documentation](https://docs.github.com/en/actions)
- [GitHub Actions secure use](https://docs.github.com/en/actions/reference/security/secure-use)
