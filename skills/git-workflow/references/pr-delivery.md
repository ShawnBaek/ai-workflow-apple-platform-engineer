# Pull request delivery

1. Review the exact diff against the accepted task and choose coherent slices. Split unrelated work; keep incompatible runtime/schema migrations together. For dependent PRs, verify each intended base and link its immediate predecessor.
2. Run checks that cover the changed behavior. Have an independent reviewer examine the current patch, reproduce relevant edge cases, and provide code locations or references. Evaluate the findings before applying them; use [code-review](../../code-review/SKILL.md).
3. Prepare a short PR body from the repository template: problem/result, checks with outcomes, and accessible proof. Link the detailed evidence report rather than copying its full matrix or usage accounting.
4. Satisfy the applicable commit/push/PR approvals at the point required by project policy. Reuse already confirmed account and destination facts; group outstanding facts into one concise request when possible. Present the prepared diff, exact destination/base, commit message and PR draft before the final gate. Name every still-missing action explicitly, including first-PR confirmation when required; commit approval alone does not grant a missing push or PR approval. Once the needed authorization arrives, continue delivery without asking the user to start each next step.
5. Publish with `gh` using the commands below. Inspect screenshots/trimmed video/JSON for private data, and verify the uploaded evidence renders for the intended reviewer.
6. Match the published head/base to the independent review. Publish its findings or concise no-findings summary as a COMMENT review when authorized; read back its ID/URL. The author checks the feedback and verifies accepted fixes. Reuse a review of the identical patch; repeat only affected review after changes. A PR-body claim of independent review is not a posted review.
7. Read back the remote head, PR base, body, proof and review. Report required CI as passed, failed, pending or unavailable exactly as observed; an empty check list is not a green build. Do not infer merge authority. If a predecessor merges, retarget only within authorization and recheck the resulting diff.

Use a shared stack plan for broad work; do not repeat a complete stack map in every body or force arbitrary phase titles. A local verification task need not create a PR. See [delivery guidance](../../agent-harness/references/delivery.md) for evidence and runtime boundaries.

## Standard GitHub CLI path

Check `gh --version`, `gh pr create --help` and `gh pr edit --help`. The installed
2.99.0 supports image/video `--attach` on both create and edit. Use the resolved
repository, explicit head/base and a body file from the repository template:

```sh
gh pr create --repo '<owner/app>' --base '<base>' --head '<approved-head>' \
  --title '<problem and result>' --body-file '<prepared-pr.md>' \
  --attach '<evidence>/screen.png#Changed screen' \
  --attach '<evidence>/interaction.mp4'
gh pr view '<PR>' --repo '<owner/app>' \
  --json url,headRefOid,baseRefName,body,reviews,statusCheckRollup
```

Resolve `--repo` to the confirmed base repository. `<approved-head>` is `<branch>`
for a same-repository PR or `<fork-owner>:<branch>` for a supported fork head;
check installed help for owner limitations. Do not drop the fork owner when
targeting upstream.

For an existing PR, add only the missing proof:

```sh
gh pr edit '<PR>' --repo '<owner/app>' \
  --attach '<evidence>/interaction.mp4'
```

Images accept optional `#alt text`; videos do not. A matching local image
reference in the prepared body is rewritten to the uploaded asset. Edit without
`--body-file` preserves the existing body and appends attachments; replacing the
body requires carrying forward already-published evidence links.

Creation/edit can partially succeed: a nonzero exit can still mean the PR exists
and some attachments uploaded. Read the returned URL or find the PR by exact
head, inspect its body, then retry only missing files. Never blindly create a
duplicate PR. Verify rendered/access-appropriate evidence, not just local paths.
`gh pr create --dry-run` may still push; prepare the draft locally before approval.

Use `gh pr review --comment --body-file` for an authorized summary review; for
exact-commit/line-level findings use `gh api` with a reviewed JSON input file and
`commit_id`. Read back the posted review's commit, ID and body. Author replies use
`gh` as well. Do not use `--approve` to stand in for an independent human reviewer.

`--attach` covers images/videos, not arbitrary JSON payloads. Link a small,
intentional sanitized evidence file or CI artifact for JSON/trace proof. If the
installed CLI lacks a needed capability, report the specific gap and use only an
authorized supported alternative; do not auto-upgrade or invent upload endpoints.

Sources: [gh pr create](https://cli.github.com/manual/gh_pr_create),
[gh pr edit](https://cli.github.com/manual/gh_pr_edit),
[gh pr review](https://cli.github.com/manual/gh_pr_review).
