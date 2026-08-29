# CloudKit Web Services security

CloudKit Web Services is the documented server interface for CloudKit record operations. It is not a generic REST interface to arbitrary iCloud services or a substitute for client entitlements.

Apple's detailed Web Services protocol reference is currently hosted in the
Documentation Archive. Use it as the official starting point, then recheck the
current CloudKit Console, container environment, key-creation flow, and a
nonproduction request before treating old setup details as current behavior.

Before implementing it, define:

1. The exact CloudKit container and database scope.
2. The server trust boundary and which operation truly requires server access.
3. The request authentication/signing method and key custody owner.
4. Least-privilege permissions, record/query scope, rate/error handling, and audit requirements.

Keep keys and tokens in an approved secret store; never put them in client binaries, repository files, examples, logs, test fixtures, or PR comments. Use a nonproduction container/environment for integration testing where possible. Verify one authorized request and one material authorization/error response, with redacted evidence.

Authoritative starting points:

- https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/SettingUpWebServices.html
- https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/Types.html
