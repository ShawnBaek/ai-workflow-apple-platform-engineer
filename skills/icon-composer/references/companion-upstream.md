# IconGen companion upstream

[`ShawnBaek/IconGen`](https://github.com/ShawnBaek/IconGen) is maintained as a
separate public companion repository. Its reviewed revision and selected source
blobs are recorded in
[`companion-upstream.json`](../contracts/companion-upstream.json).

## Boundary

- The integration is reference-only. Do not vendor or automatically copy its
  code, images, product names, generated assets, or prose.
- The upstream currently has no declared license. Public visibility does not
  itself grant a reusable license; keep `vendored_files` empty unless licensing
  and repository policy change through review.
- Do not execute upstream generator scripts during health checks or sync. They
  write artifacts inside their repository and do not expose a stable CLI
  contract.
- Re-express only generalized, independently reviewed Apple-icon rules in this
  skill. Cite the exact upstream commit and Apple primary sources in review
  evidence.
- Never create a branch, tag, Issue, or PR in IconGen from the consumer sync.

## Drift loop

The repository workflow performs a weekly and manual read-only HEAD comparison.
When HEAD differs from the reviewed revision, it creates or updates one
iOS-experts Issue containing the compare link, changed revision, selected
review surface, license state, and no-copy reminder.

The watcher does not edit this skill, open a PR, execute generators, broaden a
token, or merge. A maintainer or approved harness run then:

1. reviews the changed upstream paths at the exact commit;
2. separates Apple-general guidance from product-specific implementation;
3. updates the provenance manifest and any independently worded contract;
4. adds only minimum tests for the changed safety/behavior boundary;
5. uses the normal iOS-experts Issue → branch → review → PR path;
6. closes the drift Issue only after merge or explicit accepted evidence.

If GitHub cannot read the public upstream, report the watcher as degraded and
leave the reviewed revision unchanged. Never add a private token to compensate.
