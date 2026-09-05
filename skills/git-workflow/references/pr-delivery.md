# Pull request delivery

1. Review the exact diff against the accepted task and choose coherent slices. Split unrelated work; keep incompatible runtime/schema migrations together. For dependent PRs, verify each intended base and link its immediate predecessor.
2. Run checks that cover the changed behavior. Have an independent reviewer examine the current patch, reproduce relevant edge cases, and provide code locations or references. Evaluate the findings before applying them; use [code-review](../../code-review/SKILL.md).
3. Prepare a short PR body from the repository template: problem/result, checks with outcomes, and accessible proof. Link the detailed evidence report rather than copying its full matrix or usage accounting.
4. Satisfy the applicable commit/push/PR approvals at the point required by project policy. Reuse already confirmed account and destination facts. A request for implementation does not override an explicit first-commit approval rule.
5. Publish through supported GitHub tooling. Check the installed CLI's attachment support; use a browser attachment or CI artifact when needed. Inspect screenshots/trimmed video/JSON for private data, and verify the uploaded evidence renders for the intended reviewer.
6. Read back the remote head, PR base and body. Report required CI as passed, failed, pending or unavailable exactly as observed. Do not infer merge authority. If a predecessor merges, retarget only within authorization and recheck the resulting diff.

Use a shared stack plan for broad work; do not repeat a complete stack map in every body or force arbitrary phase titles. A local verification task need not create a PR. See [delivery guidance](../../agent-harness/references/delivery.md) for evidence and runtime boundaries.
