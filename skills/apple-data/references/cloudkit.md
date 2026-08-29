# CloudKit sync, schema, and sharing

Decide the database scope before modeling records:

- **Private database:** data owned by one iCloud account.
- **Shared database:** records shared with participants; define participant roles and acceptance behavior.
- **Public database:** app-visible data with deliberate read/write rules.

Treat the CloudKit container and the development/production schemas as release-controlled resources. Verify the selected container, entitlements, schema status, record types, indexes needed for supported queries, and sharing permissions before claiming synchronization works.

For a Core Data app, route persistent-store mirroring, history, and conflict implementation to `core-data`. For a SwiftData app, use the SwiftData reference for the persistence side and retain the CloudKit product decisions here.

Design an explicit response for offline edits, retries, conflict outcomes, deleted shared records, revoked access, and account/container unavailability when the product exposes those behaviors. Test only the material cases for the change.

Authoritative starting points:

- https://developer.apple.com/documentation/cloudkit
- https://developer.apple.com/documentation/cloudkit/ckcontainer
- https://developer.apple.com/documentation/cloudkit/shared_records
- https://developer.apple.com/documentation/coredata/mirroring-a-core-data-store-with-cloudkit
