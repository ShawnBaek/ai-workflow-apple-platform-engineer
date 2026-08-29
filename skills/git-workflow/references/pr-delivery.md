# Pull Request Delivery

Use this after implementation is ready, not as authorization to commit, push, or publish.

1. Confirm the approved repository/branch and the required first-commit or first-push gate.
2. Review the exact diff and select minimum-sufficient checks. Do not add redundant tests merely to increase count.
3. Commit and push only after their required approvals. Verify the pushed commit via the remote branch or PR, especially when linked-worktree tracking refs are stale.
4. Open or update the PR with scope, verification, omitted checks, and residual risk.
5. For requested visual proof, capture the applicable platform flow after functional verification. Put the screenshot/video where PR reviewers can open it through a supported GitHub UI or CI artifact link, then verify the rendered PR body or comment. State whether the evidence is permanent or retention-limited.
6. Check required CI and review status before declaring delivery complete. Preserve a failing result and its first actionable cause rather than blindly retrying the same input.
