# CloudKit sync, schema, and sharing

Decide the database scope before modeling records:

- **Private database:** data owned by one iCloud account.
- **Shared database:** records shared with participants; define participant roles and acceptance behavior.
- **Public database:** app-visible data with deliberate read/write rules.

Treat the CloudKit container and the development/production schemas as release-controlled resources. Verify the selected container, entitlements, schema status, record types, indexes needed for supported queries, and sharing permissions before claiming synchronization works.

## Cross-app public database verification

When one Apple-platform app produces public CloudKit records and another app consumes them, verify the complete path instead of treating either app's build as sync evidence:

1. Confirm both targets resolve to the same Apple Developer team, iCloud container identifier, CloudKit environment, public database, record type, field names, and query indexes.
2. Exercise the producer's real runtime path. For a browser-backed producer, this includes the rendered browser content and production extraction logic, not a fixture or direct HTTP substitute.
3. Perform only an explicitly authorized, bounded public-database write. Make it idempotent with stable record IDs and an update-safe save policy; do not delete unrelated records or retry partial failures without inspecting them.
4. Read the written record IDs back from the public database with the fields needed for correlation. A successful save callback alone is not sufficient evidence.
5. Run the consumer's real sync service, then verify the requested filter and sort behavior in the shipping UI. Build success or a local seed does not prove public CloudKit consumption.
6. Preserve both machine-readable evidence (container, database scope, record IDs, counts, timestamps, and errors) and visible UI evidence. Correlate producer, read-back, and consumer evidence using the same stable record IDs.

If any container, environment, schema, record-ID, or account boundary differs, stop and report the mismatch before writing or claiming end-to-end success.

For a Core Data app, route persistent-store mirroring, history, and conflict implementation to `core-data`. For a SwiftData app, use the SwiftData reference for the persistence side and retain the CloudKit product decisions here.

Design an explicit response for offline edits, retries, conflict outcomes, deleted shared records, revoked access, and account/container unavailability when the product exposes those behaviors. Test only the material cases for the change.

Authoritative starting points:

- https://developer.apple.com/documentation/cloudkit
- https://developer.apple.com/documentation/cloudkit/ckcontainer
- https://developer.apple.com/documentation/cloudkit/shared_records
- https://developer.apple.com/documentation/coredata/mirroring-a-core-data-store-with-cloudkit
