---
name: apple-data
description: Choose and safely evolve Core Data, SwiftData, CloudKit sync and sharing, or CloudKit Web Services for Apple-platform apps. Use for data architecture, migration, sync, sharing, or server-access decisions; route detailed Core Data work to the core-data skill.
---

# Apple Data Platform

Use Apple documentation and the project’s deployment target as the authority. Start by identifying the product requirement, existing persisted data, supported OS versions, sharing model, offline behavior, query needs, and whether a trusted server is actually required. Do not prescribe a rewrite when the existing store already fits the requirement.

## Route the decision

| Need | Default route |
| --- | --- |
| Existing Core Data model, `.xcdatamodeld`, custom migration, persistent history, or `NSPersistentCloudKitContainer` | `core-data` for implementation detail |
| New app model with supported deployment target and app-owned local model | SwiftData; read [swiftdata.md](references/swiftdata.md) |
| Per-person cloud sync or multi-person CloudKit sharing | CloudKit sync/sharing; read [cloudkit.md](references/cloudkit.md) |
| A trusted server needs CloudKit record access | CloudKit Web Services; read [cloudkit-web-services.md](references/cloudkit-web-services.md) |

These are composable, not interchangeable. SwiftData synchronization uses CloudKit-backed persistence; an existing Core Data app may use `NSPersistentCloudKitContainer`. There is no general-purpose arbitrary “iCloud REST API” for app data. For server access to CloudKit records, use the documented CloudKit Web Services model and its container/database permissions.

## Decision constraints

- Preserve existing data first: establish the current store/schema and a migration path before changing frameworks.
- Choose SwiftData only when its deployment, model, migration, query, and sharing requirements fit; use Core Data when its mature migration/control surface is required.
- Treat CloudKit development and production environments, container identifiers, schema deployment, private/shared/public databases, and participant permissions as separate design decisions.
- Keep web-service credentials and tokens out of source, prompts, logs, screenshots, and PR text. A server is a security boundary, not a way to bypass user or database permissions.
- State offline, sync, conflict, and sharing behavior explicitly. Do not promise real-time or conflict-free synchronization without a designed policy.

## Minimum sufficient verification

Choose the smallest test set that covers the changed contract:

- Schema/migration: one seeded old-to-new store migration and one clean-install creation path.
- Sync/sharing: a focused offline or conflict test only when that behavior is implemented or changed; otherwise document the untested boundary.
- Web service: one authorized request path plus the material authorization/error path; never use production secrets in tests.

Do not duplicate the same persistence contract at unit, integration, and UI layers. Use the Apple platform testing skill for execution evidence.

## References

- [SwiftData model, migration, and concurrency](references/swiftdata.md)
- [CloudKit sync, schema, and sharing](references/cloudkit.md)
- [CloudKit Web Services security](references/cloudkit-web-services.md)
- [Core Data implementation skill](../core-data/SKILL.md)
- [Apple data framework references](references/apple-references.md)
