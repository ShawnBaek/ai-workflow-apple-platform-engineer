# Core Data Migration Playbook

Use this when the schema changes or migration crashes appear in startup.

## 1) Build the version chain

- Keep every shipped model in the `.xcdatamodeld`.
- Ensure each version has a clear successor path.
- For non-trivial changes, create explicit `.xcmappingmodel` from `vN -> vN+1`.

## 2) Pick migration mode intentionally

Use lightweight migration when:
- added optional attributes
- renamed with proper renaming identifiers (not for CloudKit-mirrored entities once their schema is in production; see [section 7](#7-cloudkit-mirrored-stores))
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

## 7) CloudKit-mirrored stores

A store mirrored by `NSPersistentCloudKitContainer`, including SwiftData's CloudKit sync, must also fit CloudKit's schema. The store fails to load when the model has:
- unique constraints (SwiftData: `@Attribute(.unique)` or `#Unique`)
- a non-optional attribute without a default value, or an `Undefined`/`Object ID` attribute
- a relationship that is non-optional (SwiftData: a to-many is `[Item]?`, not `[Item] = []`), has no inverse, is ordered, uses the `Deny` delete rule, or points into another configuration

The production CloudKit schema is additive only: after promotion you can add record types and fields, but never rename, delete or change existing ones. Record types take their names from root entities and fields from properties (`CD_` prefix), so a renaming identifier (SwiftData: `originalName:`) migrates only the local store; the new name maps to a new CloudKit record type or field while older app versions keep using the old one. Instead, add a new optional or defaulted attribute, copy values in app code, and keep the old field while older versions are supported. For larger breaks, move to a new store and container. A `version` attribute with a fetch predicate that selects only compatible records hides newer records from an older install only if that install already filters on it, so add it from the first synced release.

Schema lifecycle:
1. After each model change, run `initializeCloudKitSchema(options:)` against the development environment from a debug-only path or a dedicated target, never in production builds. It validates the model and uploads temporary records to write the draft schema into the container's development environment, which everyone using that container shares. A SwiftData app calls it on a temporary `NSPersistentCloudKitContainer` built with `NSManagedObjectModel.makeManagedObjectModel(for:)`, then removes that store before creating its `ModelContainer` ([Apple's steps](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices#Initialize-the-CloudKit-development-schema)).
2. Check the record types in CloudKit Console. Additive draft changes need no reset. Reset the development environment (CloudKit Console or `xcrun cktool reset-schema`) only when a draft record type or field must not reach production, and only with the developer's explicit approval: it deletes all development-environment data and reverts the draft schema to production for everyone using the container.
3. Before shipping a TestFlight or App Store build that uses the schema, the developer deploys it to production in CloudKit Console as a release action with their approval; production doesn't create record types or fields on demand. Deployment can't be undone: deployed record types and fields exist for all time.
