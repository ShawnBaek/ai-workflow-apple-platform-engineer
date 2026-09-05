# Get started

iOS-experts is a collection of Apple-platform development skills, not an app
framework. Use one specialist for focused work and `native-app-lead` when the
task spans several areas. Existing skill IDs, repository URLs, and machine
contract IDs remain stable through the Swift runtime cutover.

## Install

Use the [Skills CLI](https://skills.sh/docs/cli) to select the skills and client
you need:

```sh
npx skills add ShawnBaek/iOS-experts
```

Keep one active copy of each skill in the client's configured search roots.
Check the [catalog](skills.md) for individual entry points. Native builds,
Previews, Simulator, and the Swift verifier need macOS and Xcode; use the
project's selected full Xcode without changing the global toolchain.

## Run the verifier

Build once from the installed `agent-harness` folder with Swift 6:

```sh
AGENT_HARNESS_ROOT='<absolute-installed-agent-harness>'
swift build --package-path "$AGENT_HARNESS_ROOT/verification" -c release --product apple-verify -j 1 -Xswiftc -j1
APE="$AGENT_HARNESS_ROOT/verification/.build/release/apple-verify"
"$APE" --help
```

Keep the executable beside its matching sources and contracts so runtime
identity is meaningful. Private harness files, credentials, observations, and
run ledgers stay outside repositories. Use `harness-local.json` for a
`local_verified` outcome; PR delivery uses the PR profile and its publication
conditions. See [verification](verification.md) for commands and
[migration](../skills/agent-harness/references/swift-verification.md) before
updating an existing runtime.
