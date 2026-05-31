# Core Data Migration Playbook

Use this when the schema changes or migration crashes appear in startup.

## 1) Build the version chain

- Keep every shipped model in the `.xcdatamodeld`.
- Ensure each version has a clear successor path.
- For non-trivial changes, create explicit `.xcmappingmodel` from `vN -> vN+1`.

## 2) Pick migration mode intentionally

Use lightweight migration when:
- added optional attributes
- renamed with proper renaming identifiers
- relationship updates are inferable

Use explicit mapping model when:
- entity split/merge
- custom transform semantics
- source data must be copied into new structures with defaults/business rules

Use staged migration when:
- app has many historical versions in the wild
- direct old -> latest mapping is brittle

## 3) Startup sequence recommendation

1. Build persistent container with current model.
2. Before `loadPersistentStores`, run migration preflight for file stores.
3. Log source version, target version, step count, and elapsed time.
4. Only proceed to `loadPersistentStores` after preflight success.

## 4) Testing strategy (required)

- Seed real sqlite stores from previous versions (not only in-memory).
- Add tests for:
  - old -> latest migration
  - reopen migrated store
  - readonly/open-failure recovery path (if you support one)
  - mapping model availability
- Run on both iPhone and iPad simulators for release-critical migration changes.

## 5) Failure triage map

- `NSCocoaErrorDomain 134110`: migration failure; inspect underlying sqlite reason and mapping step.
- `NSSQLiteErrorDomain 8` (`readonly`): store write/open conditions; check preflight strategy and destination write path.
- mapping model not found: resource bundle/config issue.
- incompatible model: model version detection chain issue.

## 6) Release discipline

- Document migration behavior in PR.
- Include test coverage and exact scenarios.
- If crash was in production/TestFlight, include a clear "What to Test" note focused on old-install upgrade behavior.
