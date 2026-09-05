# Original combined-candidate review record

The original combined candidate at `6a74a6c783827f8633a45c11d4b3de16ff7e7737`
rebranded the collection as Apple Platform Engineer and replaced the bundled
Python runtime with Swift. This record preserves the review evidence for that
historical candidate. It is not a claim that the later split PR heads were
reviewed or published together.

## Review scope

1. **Workflow and guidance:** intake clarification, selective ADRs and dependency
   graphs, model selection, resource limits, code-first previews,
   storyboard/code/hybrid construction, aligned image proof, motion, focused
   tests, and minimum-OS Apple API routing.
2. **Swift runtime and integration:** command surface, schema/fixture bindings,
   local and PR completion, resource contention, health probes, report
   rendering, retrieval freshness, and image geometry.
3. **Independent runtime review:** authorization/lifecycle and health parity
   against the previous implementation, including grant topology, exact lease
   ownership through dispatch/write, expiry bounds, target binding, stable
   private reads, local Spec Kit/review conditions, lease pairing, runtime UI
   protection, and duplicate identifiers.
4. **Functional-audit recheck:** CI wording, CoreSimulator acquisition order,
   and the model probe's missing-artifact and unavailable-model claims. The
   corrected model probe ran on macOS 27 and typechecked for iOS 17; no older-OS
   execution or model inference was claimed.

The published combined candidate passed its 75-test Swift suite and repository
validation in [GitHub Actions run 33965502424](https://github.com/ShawnBaek/iOS-experts/actions/runs/33965502424).
The bounded independent publication recheck is recorded in
[PR 22 review 5121267464](https://github.com/ShawnBaek/iOS-experts/pull/22#pullrequestreview-5121267464).
Those links support only commit `6a74a6c`; they do not establish results for a
new split branch.

## Proof boundaries

- [Reporting walkthrough](maintenance-walkthrough.md) used simulated reporting
  cases. It did not create a live issue.
- [Comparison example](README.md) used synthetic fixtures with known signed
  offsets and preserved input hashes.
- Health regressions used injected success, mismatch, and timeout responses.
  They did not establish App Store Connect credentials, MCP availability,
  Simulator execution, or app performance.
- The five native framework probes ran their stated macOS non-model paths; the
  final sources also received serialized iPhoneOS SDK typechecks. Foundation
  Models reported `modelNotReady`. No iOS executable or Simulator flow ran.
- Figma guidance was checked against official tool and setup documentation; no
  live Figma file or node was exported.

For the replacement series, keep the executable, machine contracts, fixtures,
and trust bindings together in the runtime activation PR. Review Swift
implementation layers and later documentation as the smaller slices in the
split manifest. New local and CI results must be recorded against each actual
head; the old combined review does not transfer automatically.

## Split preparation verification

The replacement series was assembled into 16 incremental trees. Each of the
nine Swift implementation/activation slices compiled and passed its available
tests; all eight trees from contract activation through final documentation
passed the Swift repository validator. The final tree passed all 64 XCTest and
11 Swift Testing cases. Swift fixture generation and the comparison CLI were
rerun; the annotated image showed the expected +3 pt horizontal and +6 pt
vertical offsets. These are local results; replacement PR CI has not run.

The split review caught an early removal of legacy CI coverage. The additive
Swift PRs now retain the existing checks; the activation PR replaces them only
when the complete Swift test suite and repository validator are available.
Three authorization-policy tests and the exclusive action-request test were
moved earlier after passing against the existing contracts. The local-outcome
schema test remains with its changed schema. Shared declarations and Spec Kit
tests moved to separate files so each implementation slice can compile.
