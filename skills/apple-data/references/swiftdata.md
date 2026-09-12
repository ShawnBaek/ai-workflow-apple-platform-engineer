# SwiftData model, migration, and concurrency

Use SwiftData for a new app only after confirming the app’s deployment target and data requirements fit its APIs. Model changes are persisted-data changes: identify the shipped schema, choose the migration strategy supported by the app, and preserve an explicit route from every supported prior version.

- Keep model ownership and mutation within a clear concurrency boundary. Pass stable identifiers or value snapshots between isolation domains instead of assuming model instances are safe everywhere.
- Keep UI-facing model access on the appropriate UI isolation boundary; keep imports, transforms, and long-running work out of it.
- For a model change, verify one seeded old-store migration and one clean-install path. Add a conflict/offline scenario only when sync semantics are part of the change.
- When enabling CloudKit synchronization, validate the container, entitlement, schema deployment stage, and expected database/sharing behavior instead of treating the setting as an opaque toggle.

Authoritative starting points:

- https://developer.apple.com/documentation/swiftdata
- https://developer.apple.com/documentation/swiftdata/modelcontainer
- https://developer.apple.com/documentation/swiftdata/modelconfiguration
- https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices
