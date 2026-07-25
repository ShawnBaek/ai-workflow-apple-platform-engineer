---
name: xcode-project-workflow
description: Enforce the required Xcode project directory, Git feature-branch, and XcodeGen workflow for Apple-platform tasks. Use before any Xcode project edit, build, test, debugging, or XcodeGen operation.
---

# Xcode Project Workflow

Use this skill as a mandatory preflight for every Apple/Xcode project task.

## Mandatory preflight

1. Identify the exact existing directory containing the `.xcodeproj` or
   `.xcworkspace` that the developer opened first. Use that directory for all
   edits, builds, tests, debugging, and generated files.
2. If that project root is unknown, stop and ask the developer. Never guess,
   search for another checkout, copy the project, or create a sandbox/worktree.
3. Inspect the repository path, current branch, remote, and working tree.
4. Do not continue on the currently checked-out branch. Identify `origin/main`
   or `origin/master` as the remote default starting point.
5. Propose one concise feature-branch name and ask the developer to approve it.
   Do not edit files, implement changes, or perform substantive validation
   before approval.
6. After approval, create the feature branch from the remote default branch in
   the same existing checkout. Never use a Git worktree or alternate checkout.
7. Verify the final project root and branch before implementation.

If the working tree has uncommitted changes or the remote default branch cannot
be safely identified, stop and ask how to proceed.

## Xcode and XcodeGen rules

- Keep the project in the directory already opened in Xcode so the developer
  can manually build and debug the same Xcode window and checkout.
- Never create, switch to, or use a worktree, copied repository, temporary
  project directory, or alternate sandbox location for an Xcode task.
- If XcodeGen is used, do not run `xcodegen generate` while the current Xcode
  session is open. Do not infer that regeneration is needed because files were
  added, removed, or edited.
- Run XcodeGen only when the developer explicitly requests it or when a
  genuinely new Xcode session must be opened after project-spec changes.
- Before permitted regeneration, announce it, confirm the project root, and
  run it there. Never generate into another directory.

## Stop conditions

Stop and ask the developer if the first-opened project directory is unknown,
the checkout is not clean, the remote default branch cannot be resolved, the
branch name is not approved, or XcodeGen seems useful without explicit
permission or a new Xcode session.
