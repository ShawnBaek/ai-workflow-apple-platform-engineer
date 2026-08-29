# Pull Request Delivery

Use this after implementation is ready, not as authorization to commit, push, or publish.

1. Confirm the approved repository/branch and the required first-commit or first-push gate.
2. Review the exact diff and select minimum-sufficient checks. Do not add redundant tests merely to increase count.
3. Compare the diff with the approved phase map. If it now contains another independently reviewable contract or crosses the review-size checkpoint, stop and split it before publication.
4. Commit and push only after their required approvals. Verify the pushed commit via the remote branch or PR, especially when linked-worktree tracking refs are stale.
5. Open or update the PR with scope, verification, omitted checks, and residual risk.
6. For requested visual proof, capture the applicable platform flow after functional verification. Put the screenshot/video where PR reviewers can open it through a supported GitHub UI or CI artifact link, then verify the rendered PR body or comment. State whether the evidence is permanent or retention-limited.
7. Check required CI and review status before declaring delivery complete. Preserve a failing result and its first actionable cause rather than blindly retrying the same input.

For a stack, title each PR `Phase N/M: <reviewer outcome>` and include the same
ordered stack map: phase, branch, PR link or pending marker, base, dependency,
scope, and checks. The first phase targets the repository default branch; each
later phase targets its predecessor branch until the predecessor merges. Verify
the GitHub base/head read-back for every PR. After a predecessor merges, retarget
only with authority and reverify the resulting diff; never hide stack state with
a force push.
