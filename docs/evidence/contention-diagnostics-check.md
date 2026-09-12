# Contention diagnostic regression

Date: 2026-09-06. Baseline: `572659db7fd56b1b13abb93cb48e9433dfa1773f`.

The coordinator already knew the conflicting lease ID or exhausted capacity
dimension, but its CLI catch handler discarded that detail. The fix retains a
bounded structured `reason_detail` only for known contention values. Other errors
retain the original two-field response and exit code 2; arbitrary private error
text is not exposed. Admission, ownership, expiry and authorization are unchanged.

Swift verification used Xcode 27 beta / Swift 6.4 with one build worker:

- Full package: **69 XCTest + 12 Swift Testing tests passed**.
- The new contention regression, with the original two-field response behavior
  substituted behind the same helper signature, executed and failed on the two
  missing detail assertions. Restoring the exact fixed source made it pass.
- The CLI regression preserved non-contention response shape and exit code.
- Repository validation passed. No live private coordinator was mutated.

An initial test run with a nonstandard task scratch path failed because existing
CLI tests expect the package-local `.build` executable. The successful run used
that task-owned location; the initial failure is not hidden or counted as a pass.

This verifies response diagnostics and their privacy boundary. It does not prove
automatic lease cleanup, faster app builds, five simultaneous repository writers,
or repair of installed runtime bindings. Installation/migration remains separate.
