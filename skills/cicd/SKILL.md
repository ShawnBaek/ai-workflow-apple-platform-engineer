---
name: cicd
description: >-
  Designs safe GitHub Actions CI/CD for Apple-platform projects on hosted or self-hosted macOS runners. Use for build/test workflows, runner setup, package caching, evidence artifacts, secrets/variables, TestFlight release gates, workflow security, failure triage, or runner disk pressure. Applies least privilege, minimum-sufficient checks, scoped cleanup, and pull-request delivery without auto-merge.
---

# Apple CI/CD

Build the smallest pipeline that protects the affected contracts. Hosted macOS
and self-hosted Mac runners are both valid; choose from cost, required Xcode,
signing, hardware, queue, and isolation needs rather than declaring one universal.

## Load the relevant guide

| Concern | Read |
|---|---|
| runner registration/isolation | [self-hosted-runner.md](self-hosted-runner.md) |
| build/test/release examples | [workflow-templates.md](workflow-templates.md) |
| local/static workflow checks | [act-local-testing.md](act-local-testing.md) |
| secrets versus variables | [secrets-and-variables.md](secrets-and-variables.md) |
| disk audit and failure triage | [cleanup-and-debug.md](cleanup-and-debug.md) |

## Design order

1. Resolve repository/account, branch rules, authoritative Xcode container, and
   required Xcode build/platforms.
2. Choose events and the risk-derived check set. Do not run a 4-platform/device
   matrix when only a documentation or isolated route changed.
3. Set explicit job permissions, timeout, concurrency, and runner labels.
4. Pin dependencies/actions according to repository security policy. Never run
   untrusted PR code in a privileged `pull_request_target` or `workflow_run` job.
5. Preserve `Package.resolved` and use `swift-package-manager` policy. A build
   must not silently update dependency versions.
6. Build-for-testing once and test-without-building only for an identical tuple.
7. Upload concise logs, `.xcresult`, screenshots/video, and manifests on the
   relevant success/failure path with digest and retention stated.
8. Route failures by layer; do not rerun a deterministic signature unchanged.
9. Prepare commit/push/PR through `git-workflow`; never auto-merge.

## Credentials and external writes

Sensitive values are secrets; non-sensitive configuration is a variable. Use
environment/repository scoping and least privilege. Do not echo or interpolate
private key material into logs or command history. Upload, TestFlight
distribution, App Store submission, certificate changes, Project updates, and
branch/ruleset changes are separate gated external mutations.

Remember that pushes made with the repository `GITHUB_TOKEN` generally do not
recursively trigger another workflow. Do not silently swap in a broader token.

## Disk policy

Every job should clean only paths it created and can name exactly. Ephemeral
hosted runners normally need no user-library cleanup. Long-lived runners use a
read-only `xcode-storage` audit, retention budgets, and itemized approval.
Never blanket-delete DerivedData, Simulator state/runtimes, SwiftPM caches,
archives, Homebrew caches, or runner workspaces in `if: always()`.

## Failure evidence

Report workflow/run/job, runner/Xcode, package fingerprint, first actionable
diagnostic, relevant artifact link/digest, and whether failure is environment,
package, compile/link, signing, assertion/runtime, upload, or policy. A local
`act` run can validate suitable Linux/container steps; it is not proof that an
Xcode/macOS job works.

## Never

- broaden scopes, change account, weaken branch protection, or use force push;
- execute fork PR code with write tokens/secrets;
- auto-install tools or mutate a shared runner without approval;
- use cleanup as a substitute for diagnosing package/build invalidation;
- mark a flaky rerun green without retaining the original failure;
- upload, submit, merge, or rotate signing credentials from a build-only request.

References:

- [GitHub Actions](https://docs.github.com/en/actions)
- [Secure use reference](https://docs.github.com/en/actions/reference/security/secure-use)
- [Workflow artifacts](https://docs.github.com/en/actions/concepts/workflows-and-actions/workflow-artifacts)
- [Apple Swift package CI guidance](https://developer.apple.com/documentation/xcode/building-swift-packages-or-apps-that-use-them-in-continuous-integration-workflows)
