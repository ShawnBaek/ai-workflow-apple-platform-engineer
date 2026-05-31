# Core Data Concurrency Patterns

## Baseline topology

- `viewContext`: UI-facing, main actor.
- background context(s): imports, cleanup, expensive writes.
- optional persistent history + remote-change notifications for multi-writer/sync setups.

## Safe transfer rules

- Pass `NSManagedObjectID`, not `NSManagedObject`, across actor/context boundaries.
- Rehydrate objects in destination context with `existingObject(with:)`.
- For async workflows, pass value DTO snapshots when possible.

## Merge policy guidance

Choose intentionally per flow:
- UI edits with local authority: object trump can be acceptable.
- sync-heavy shared updates: consider store trump or domain-specific resolution.

Document why the policy is chosen.

## Background write pattern

1. Create background context from persistent container.
2. Perform fetch/insert/update inside context queue.
3. Save background context.
4. Ensure UI context merges changes (`automaticallyMergesChangesFromParent` or explicit merge).

## Anti-patterns to block

- Direct object mutation on wrong context thread/actor.
- Doing heavy imports/migrations on main context.
- Force-unwrap fetch assumptions inside migration or startup code.
- Silent conflict overwrite without explicit product rule.

## Observability

For critical paths, log:
- operation name
- context type (view/background)
- object counts affected
- elapsed time
- error chain

Keep logs lightweight in release and verbose in debug/diagnostic mode.
