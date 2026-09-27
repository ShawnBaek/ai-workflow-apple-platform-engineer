Read and follow `AGENTS.md`, then load `skills/apple-platform-engineer/SKILL.md`
for broad or end-to-end work. Load `skills/agent-harness/SKILL.md` only when
AGENTS.md calls for it: guarded execution is selected (the guarded apple-verify
runtime, not the repository validator; Codex-and-Claude collaboration, resource
leases, run authorization or local RAG), or the change touches the harness's
runtime or contracts. Writer and reviewer roles follow the
[mode contract](skills/agent-harness/references/collaboration.md#mode-contract):
in collaborative mode Claude writes only when `selected_writer` names it and
otherwise reviews read-only; never infer a writer-lease transfer.
