# ADR 0003: Separate consumer preferences from runtime contracts

Status: accepted · Date: 2026-09-12 · Owner: repository maintainer

## Context

The collection is intended for open-source reuse. Some guidance applied the
maintainer's design, tracking and website preferences to every consumer. The
standalone entry points also appeared to require the guarded runtime for any PR.

## Decision

Use standalone specialist guidance by default and select guarded orchestration
for explicit runtime or coordinated shared-resource work. Resolve consumer
preferences from current project/user instructions. Keep private account/design/
board information outside public distribution and use synthetic proof fixtures.
Provide MIT licensing for the collection, without relicensing linked projects.

Do not convert safety invariants into unchecked preferences. Keep existing
runtime schemas, one-writer ownership, authorization, expiry/replay checks,
tracked PR profile and bounded attempts unchanged. Unsupported runtime profiles
require a separate coherent migration. Never bypass an active guarded run.

## Consequences

Individuals and teams can choose existing tools, design sources and tracking
without installing unrelated integrations. The supported runtime remains more
constrained than the Markdown guidance; documentation must say so. Public source
links remain provenance. Removing consumer data from the tip does not erase old
commits; history rewriting is a separate operation requiring explicit authority.

This applies ADR 0001's smallest-fitting-workflow policy without changing persisted
runtime identities. Acceptance uses synthetic command tests and fresh-agent
decision evaluation, not live writes to consumer accounts.
