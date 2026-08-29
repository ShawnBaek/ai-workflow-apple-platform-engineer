# Failure diagnosis

Classify the first failure before retrying:

| Layer | Typical signal | Next action |
| --- | --- | --- |
| Resolution | version solver conflict, registry/network/authentication error | inspect manifest, lockfile, repository reachability, and authorized credentials |
| Checkout | revision unavailable, corrupt/missing checkout, source fetch failure | compare selected revision with lockfile and inspect the specific checkout/cache state |
| Compile | Swift type/module/compiler error | fix source/API/toolchain compatibility; do not re-resolve by default |
| Link/package product | missing product, duplicate symbol, architecture/platform mismatch | inspect target linkage, product name, platform and build settings |

Repeat a command only when an input or transient external condition changed. If the same failure signature recurs with unchanged inputs, stop and report the evidence instead of repeatedly resolving or clearing caches.

For Xcode or Simulator commands, follow the repository's host-execution boundary; a sandbox permission failure is infrastructure evidence, not a package failure.
