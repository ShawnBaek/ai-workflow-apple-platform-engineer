# ADR 0001: Use graphs when dependencies justify them

Status: accepted · Date: 2026-09-05 · Owner: repository maintainer

## Context

This collection serves small local edits and multi-part delivery. Requiring a
full task graph for every edit adds state and review work without necessarily
improving correctness.

## Decision

Use a direct action or simple plan by default. Add an execution graph when a
specific dependency, join, invalidation relationship, or shared resource makes
it useful for correctness, scheduling, or verification. Explain that dependency
and keep only the necessary nodes and edges. Numbers of files, skills, agents,
or planned PRs are not sufficient justification.

Simple tasks retain the same applicable authorization, ownership, and evidence
checks. The execution graph is task planning; a small set of mandatory safety
checks does not require turning every check into a user-visible task node.

## Consequences and alternatives

A graph for every task provides uniform shape but unnecessary overhead. Never
using graphs hides complex dependencies. Conditional use keeps simple work
small while making actual coordination inspectable. Introduce matching runtime
outcomes before claiming a local task can bypass an existing PR-only contract.

Reviewers should be able to explain what every nontrivial dependency contributes.
The maintainer accepted this decision as part of the Apple Platform Engineer
workflow revision. Future changes supersede this record instead of silently
rewriting its accepted decision.
