# CloudKit sync, schema, and sharing

Decide the database scope before modeling records:

- **Private database:** data owned by one iCloud account.
- **Shared database:** records shared with participants; define participant roles and acceptance behavior.
- **Public database:** app-visible data with deliberate read/write rules.

Treat the CloudKit container and the development/production schemas as release-controlled resources. Verify the selected container, entitlements, schema status, record types, indexes needed for supported queries, and sharing permissions before claiming synchronization works.

For a Core Data app, route persistent-store mirroring, history, and conflict implementation to `core-data`. For a SwiftData app, use the SwiftData reference for the persistence side and retain the CloudKit product decisions here.

Design an explicit response for offline edits, retries, conflict outcomes, deleted shared records, revoked access, and account/container unavailability when the product exposes those behaviors. Test only the material cases for the change.

## Cross-app public database verification

When one Apple-platform app produces records and another consumes them, verify the
whole contract instead of treating either app's successful UI action as sync proof:

1. Resolve the producer and consumer's exact entitlements, CloudKit container,
   environment, database scope, record type, field names, and query indexes. Stop
   on any mismatch; a matching record model in source is not proof that both apps
   use the same live database.
2. Exercise the producer through its real runtime path. For web-backed ingestion,
   keep extraction, normalization, deduplication, and CloudKit persistence as
   separately observable steps so an empty result or rejected record is localized.
3. Make live public-database writes bounded and idempotent. Obtain explicit
   authorization immediately before the mutation, record the attempted record
   identity and timestamp, avoid cleanup or bulk deletion, and read the exact
   record back from the same container and database.
4. Launch the consumer through its real synchronization service. Prove that the
   read-back record becomes the consumer's local model with the expected identity
   and material fields, then verify the requested sort/filter behavior in the UI.
5. Capture two kinds of evidence: machine-readable read-back (container,
   database scope, record type, record ID, and relevant timestamps) and runtime UI
   evidence from both producer and consumer. Redact account identifiers, tokens,
   and unrelated user data. A producer success alert, a passing build, or a
   consumer screenshot alone does not prove end-to-end synchronization.

Use one stable record identifier across producer write, CloudKit read-back, and
consumer display evidence whenever the product model permits it. If the UI cannot
display that identifier, match a small, non-sensitive field tuple such as title,
company, source URL, and fetched timestamp and state that this is correlation
rather than identity proof.

Authoritative starting points:

- https://developer.apple.com/documentation/cloudkit
- https://developer.apple.com/documentation/cloudkit/ckcontainer
- https://developer.apple.com/documentation/cloudkit/shared_records
- https://developer.apple.com/documentation/coredata/mirroring-a-core-data-store-with-cloudkit
