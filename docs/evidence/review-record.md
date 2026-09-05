# Migration review record

This change rebrands the collection as Apple Platform Engineer and replaces every bundled Python helper/test with the Swift verifier. Existing skill invocations, public repository coordinates and persisted contract identifiers remain intentional. Coordinator state advances to version 2 with explicit quiescent migration and new executable/source bindings.

## Three review passes

1. **Scope and workflow:** checked intake clarification, selective ADRs/dependency graphs, coherent PR slices, model selection, resource limits, code-first previews, storyboard/code/hybrid construction, aligned design proof, motion, focused tests, and minimum-OS Apple API routing. The [research comparison](../research-notes.md) records primary engineering and Apple sources.
2. **Behavior and integration:** checked the complete Swift command surface, schema/fixture bindings, local and PR completion, resource contention, health probes, report rendering, retrieval freshness and image geometry. The Swift suite covers malformed inputs, denial/expiry, replay, real child-process contention and bounded process output. CI uses the same package and repository validator.
3. **Independent review and author response:** a separate reviewer challenged authorization/lifecycle and health parity against the previous implementation. Accepted fixes covered grant topology, exact active ownership through dispatch/write, expiry bounds, produced-target binding, one-snapshot private reads, local Spec Kit/review conditions, deterministic lease pairing, runtime UI protection and duplicate IDs. The reviewer rechecked these fixes. An alleged delivery-template bypass was disputed: the checked-in schema already rejects those inputs before rendering authorization; schema-valid negative cases support that disposition.

## Proof and limits

- [Reporting walkthrough](maintenance-walkthrough.md): independent simulated cases covered sanitized upstream reporting, app-only bug routing and uncertain-create recovery. Contributor guidance explains how to repeat focused evaluations and verify workflow fixes. No live report was filed.
- [Comparison example](README.md): visually inspected clean/annotated synthetic fixtures with known signed offsets and preserved input hashes.
- Local verification: full Swift tests and `apple-verify repository --root .`; see CI for results against a published commit.
- Health tests use injected valid/mismatch/timeout responses. They do not claim real GitHub/ASC credentials, MCP connectivity, Simulator execution, or an Apple app performance result.
- No app was changed, so no app XCUITest suite or Simulator recording was added. Swift regression tests target the runtime's actual contracts; model-quality and animation guidance still require evidence from the consuming app.

The runtime/schema replacement is one atomic review slice because mixing versions would break trust bindings and consumers. Future unrelated features should follow the documented smaller PR workflow.

## Functional audit review

The follow-up [34-skill audit](skill-functional-audit.md) was independently
reviewed from a frozen diff and copied probes. Three findings were accepted:

- **CI evidence:** a forward reference to future PR checks was not an observed
  result. The JSON now states `not_run: no published candidate commit or pull request`.
- **Simulator discovery order:** inventory appeared before its required shared
  registry lease in the numbered instructions. Acquisition now precedes
  inventory, and release precedes acquiring the exact device lease.
- **Model probe scope:** a missing-file rejection was labeled as a bounded
  loader, and older macOS could silently skip Core AI. The label now names only
  the rejected missing artifact; unsupported OS versions get an explicit
  blocker. The corrected source was compiled/run on macOS 27 and typechecked
  for an iOS 17 deployment; no older-OS execution or inference is claimed.

The reviewer checked the Figma corrections against current official tool/setup
documentation and found no concrete defect in those changes. Reviews and author
responses remain local because the candidate has not been committed or published.
The reviewer reread the frozen corrections and confirmed all three findings
resolved, with no remaining concrete issue in that recheck.
