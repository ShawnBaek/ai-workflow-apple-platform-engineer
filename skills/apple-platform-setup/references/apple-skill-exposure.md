# Expose Apple's Xcode skills

Each Xcode ships Apple-authored agent skills. This reference owns how an agent
reaches them: when `xcrun agent` may run, the one exposure each selected Xcode
gets, what to record, and how to take an inventory without exporting. Other
skills link here instead of restating it. Apple's skills own SDK facts and
Apple-defined tasks for that Xcode; this collection owns project process.

## `xcrun agent` is `mcpbridge run-agent`

`xcrun agent` runs `Contents/Developer/usr/bin/agent` in the selected Xcode, a
signed three-line shell script that ends in
`exec "$SCRIPT_DIR/mcpbridge" run-agent "$@"`. Every `xcrun agent` call,
`--help` included, is therefore a `mcpbridge run-agent` call. Its `skills export`
and `plugin path` subcommands reach Xcode over XPC, and `mcpbridge` can launch
Xcode hidden or its headless XcodeService to answer them. Observed on 2026-09-28
in Xcode 27.1 (27A9269) and 27.2 beta (27B5019j) by reading the files with
`cat`, `grep` and `strings`; inspect these tools only that way.

Run a `run-agent` subcommand only through this skill, after the person
explicitly approves the client or clients, the scope in each, the target folder
and the Xcode (path, version and build). Never run one as a health probe, a
discovery step or a `--help` check, and never from another skill.

- `skills export [<folder>]` writes one flat folder per skill, a `SKILL.md` and
  any reference files, into the folder given, or into `./xcode-skills` in the
  current directory when none is given. It skips a skill whose folder already
  exists unless `--replace-existing` is passed. It reports exported and skipped
  counts but, unlike Xcode's rendering for its own agents, no removals, so do
  not expect it to remove a skill that a later Xcode renamed or dropped. The
  exported files record no Xcode version or build. Apple names this command for
  using the skills in other tools
  ([WWDC26 session 278](https://developer.apple.com/videos/play/wwdc2026/278/),
  at 15:05).
- `plugin path --plugin-format <name>` materializes Xcode's packaged plug-in
  content and prints its path. Apple does not document the format values and
  this collection has not verified them, so it is not an exposure route yet.

## One exposure per selected Xcode

Give each agent one copy of the selected Xcode's Apple skills, never two.

### Inside Xcode

Xcode gives the agents it runs its built-in skills, a different way per client:

- **Claude Agent** gets them from the Xcode-managed `xcode-integration`
  plug-in, named `xcode-integration:<skill>`.
- **Codex** gets Xcode's own copy in `skills/__xcode/<skill>` of the Codex home
  that Xcode sets for it, under plain names such as `swiftui-specialist`. Xcode
  rewrites that folder and removes skills the selected Xcode no longer ships.

Use those. Never also add exported copies for them as a plug-in in
Intelligence settings or in the `~/Library/Developer/Xcode/CodingAssistant`
configuration folders
([customizing agents](https://developer.apple.com/documentation/xcode/extending-and-customizing-agents)).
The likeliest way that happens is the Plug-ins row's import: "Import from
Claude Code" and "Import from Codex" copy the skills they find for that client
into `CodingAssistant/AgentPlugins` as plug-ins, each with an `importSource` in
its `plugin.json`, and both of Xcode's agents get those copies. Deselect every
Apple skill in that sheet, linked exports included.

By default Xcode starts Claude Agent with `CLAUDE_CONFIG_DIR` and Codex with
`CODEX_HOME` pointing into its own `CodingAssistant` folders, so Codex does not
read `~/.codex/skills`, and Claude Agent reads `~/.claude/skills` only through
Xcode's import of user Claude settings (the `IDEChatImportUserClaudeSettings`
default). While that import is on, Xcode brings the folder's skills into
Claude Agent as one synthesized plug-in; whether it follows linked skill
folders is unverified, so assume it does. Codex has no such import. Xcode can
also set `CLAUDE_CONFIG_DIR` to a UserDefaults override path, likely the
`IDEChatOverrideAgenticHomeDirectory` default; while that is set, Claude Agent
reads `skills` in the folder it names. Xcode's agents also read the roots that
do not depend on those variables. A link in any of these roots reaches them as
a second copy:

- Claude Agent: the repository's `.claude/skills`, `~/.claude/skills` while
  the import is on, and `skills` in the override folder while one is set.
- Codex: `~/.agents/skills`, `/etc/codex/skills`, and the repository's
  `.agents/skills` and `.codex/skills`, trusted or not (step 3).

Observed on 2026-09-28 in the `CodingAssistant` folders and the framework
strings of Xcode 27.1 (27A9269) and 27.2 beta (27B5019j), where both defaults
were unset and Claude Agent had none of the `~/.claude/skills` skills; recheck
them for another Xcode.

### Outside Xcode, for Claude Code or Codex

1. **Ask once** for the approvals above. The folder is dedicated to one Xcode
   build, such as `<parent>/xcode-<build>`, absent or empty, and outside every
   client skill root, `CodingAssistant` and repository checkout. Choose one
   scope per client and never link the same names in both (step 3 says why).
   Prefer user scope, in a root that Xcode's agents do not read:
   - Claude Code: `$CLAUDE_CONFIG_DIR/skills`, by default `~/.claude/skills`.
     Before choosing it, ask the person whether Xcode imports their Claude
     settings or overrides Claude Agent's home, or read both defaults without
     changing them:

     ```sh
     defaults read com.apple.dt.Xcode IDEChatImportUserClaudeSettings
     defaults read com.apple.dt.Xcode IDEChatOverrideAgenticHomeDirectory
     ```

     For the import, `1` means on and `0` off. Both keys were unset, with the
     import off, in the builds observed above; for another Xcode, ask the
     person before treating an unset key as off. While the import is on and
     the root is `~/.claude/skills`, or the override names the folder that
     holds the root, link there only with the person's recorded acceptance of
     two copies in Xcode's Claude Agent, or after the person turns the
     setting off.
   - Codex: `$CODEX_HOME/skills`, by default `~/.codex/skills`. openai/codex
     `rust-v0.144.1` still loads it as a deprecated user location; Codex's
     documentation lists only `~/.agents/skills`, which Xcode's Codex also
     reads. Use `~/.agents/skills` only when the person does not use Codex in
     Xcode, and record that answer. If a later Codex stops loading
     `$CODEX_HOME/skills`, stop and report instead of moving the links.

   Project scope, the repository's `.claude/skills` or `.agents/skills`, also
   reaches Xcode's agents working in that repository. Use it only when the
   person does not use them there or knowingly accepts two copies, and record
   which. While a user-scope exposure exists, a repository that pins another
   Xcode gets no second one: report the mismatch.
2. **Export once**, selecting the Xcode for that command:

   ```sh
   DEVELOPER_DIR='<selected Xcode>/Contents/Developer' xcrun agent skills export '<dedicated folder>'
   ```

   Always name the folder. Never pass `--replace-existing`: a new folder does
   not need it, and in a shared root such as `~/.agents/skills` or
   `~/.claude/skills` it overwrites folders this collection does not own.
   Anything skipped in a new folder means it was not empty: stop and report.
   Right after exporting, compare the folder with the selected Xcode's
   [inventory](#inventory-without-exporting): `mcpbridge` exports from the
   Xcode process it discovers, and which one answers while another Xcode build
   is running is unverified. A listed name missing from the export means
   another Xcode answered or the export failed; stop and report before
   linking or recording. For 27.1 against 27.2 beta, `app-resizability`
   against `uikit-app-modernization` shows it.
3. **Check names before linking.** For each exported skill, list the roots the
   client reads. Claude Code: enterprise skills in the managed settings
   directory, `$CLAUDE_CONFIG_DIR/skills` (by default `~/.claude/skills`), and
   `.claude/skills` from the working directory up to the repository root and
   in its subdirectories. Codex: `~/.agents/skills`, `$CODEX_HOME/skills` (by
   default `~/.codex/skills`), `/etc/codex/skills`, and `.agents/skills` and
   `.codex/skills` in each folder from the working directory up to the
   repository root. Codex reads a project's `.codex/skills` even when the
   project is untrusted: trust gates only its config, hooks and rules. A
   same-name entry that is not this exposure's link is a conflict: report it
   and wait for the person's decision. Claude Code runs an enterprise skill
   over a same-name personal one and a personal one over a project one; Codex
   lists both copies.
4. **Link each skill folder** into each approved client, one link per skill,
   creating the root first if it is missing. Resolve `CLAUDE_CONFIG_DIR` and
   `CODEX_HOME` as the client itself runs: in an agent that Xcode started they
   point into `CodingAssistant`, which is never a target.

   ```sh
   ln -s '<dedicated folder>/<skill>' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/<skill>"  # Claude Code, user scope
   ln -s '<dedicated folder>/<skill>' "${CODEX_HOME:-$HOME/.codex}/skills/<skill>"  # Codex, user scope
   ```

   For project scope, link into the repository's `.claude/skills/` or
   `.agents/skills/` instead and leave the links uncommitted. Claude Code reads
   `SKILL.md` from a linked folder's target and picks up the change in a running
   session; run `/reload-skills` when the skills directory did not exist at
   session start. Codex follows linked skill folders in its user, repository
   and admin locations; restart it if a skill does not appear.
   Neither client's settings add the folder itself as a skill root: Claude
   Code's `--add-dir` loads only an added directory's `.claude/skills/`, for
   one session, and `permissions.additionalDirectories` grants file access and
   loads no skills; Codex's `[[skills.config]]` entries only enable or disable
   skills it already found.

When the selected Xcode changes, get the same approvals for the new build,
export it into its own folder, remove only the links the old record lists
(`rm '<link>'` on each link, never `rm -r`) and link the new folder's skills.
The set differs between builds: on 2026-09-28, 27.1 has `app-resizability`
where 27.2 beta has `uikit-app-modernization`. Route by capability, never by a
hard-coded Apple skill name. Keep the old folder until the person removes it.

## Record the exposure

Keep the record in the private setup note, outside every skill root: Xcode path,
version and build (`xcodebuild -version` under the same `DEVELOPER_DIR`), the
folder, the exported and skipped counts, each link with its client and scope,
the person's answer when a link sits in a root Xcode's agents also read or may
read (for the Claude Code root, both Xcode settings from step 1 and whether
they were read or asked), the date, and the export digest:

```sh
cd '<dedicated folder>' && find . -type f ! -name .DS_Store -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256
```

The digest covers every file's relative path and content. Inside Xcode, record
the Xcode build and each client's provider: the `xcode-integration` plug-in for
Claude Agent, Xcode's `__xcode` copy for Codex. Guarded runs also put the
provider, build and digest in their evidence.

## Apple folders are foreign

An Apple export and the links into it are not collection files. Collection
updates, link reconciliation, broken-link pruning and storage cleanup never
remove, overwrite or relink them: they report them. The same holds for Apple
skill folders copied straight into a client root by an earlier export: the
inventory reports them `reserved`, and only
[Retire an old export](#retire-an-old-export) moves them. Xcode's own copies,
the `xcode-integration` plug-in and the `__xcode` folder in the Codex home
Xcode sets, belong to Xcode: never edit, link into or remove them. Apple skills imported into
`CodingAssistant/AgentPlugins` are plug-ins the person manages in Intelligence
settings: report them and leave removal to the person. Only the steps above
change an exposure, with approval, and only for the links its record lists, or
the retirement below on the person's answer for each entry. Deleting an export
folder is the person's decision.

### Retire an old export

An earlier export can leave Apple skills that no record lists: flat copies in a
client root, or links into an export folder. Retire them one entry at a time:

1. **Identify** them from the inventory's `reserved` entries: an Apple skill
   folder copied into a client root, or a link whose target is an export that
   no record lists.
2. **Show the person the evidence** for each entry: its path and resolved
   target, its modification date, and whether a recorded export or Xcode's
   built-in skills already cover it.
3. **Move it on that entry's answer**, never deleting: move the folder, or the
   link itself after recording its target, into the setup backup folder
   outside every skill root, and record the move for rollback:

   ```sh
   mkdir '<backup folder>/<root>-<entry name>' && mv '<entry path>' '<backup folder>/<root>-<entry name>/'
   ```

   `mkdir` stops if that backup entry already exists, so nothing in the backup
   is replaced. Do not add a trailing `/` to `<entry path>`: for a link it would
   move the target instead.

4. **Leave Xcode plug-in imports to the person.** For an Apple skill in
   `CodingAssistant/AgentPlugins`, ask them to remove it in Xcode › Settings ›
   Intelligence › Plug-ins.
5. **Never touch Xcode's own copies**, the `xcode-integration` plug-in and the
   `__xcode` folder.
6. If the person still wants Apple skills outside Xcode, make one per-build
   export as [Outside Xcode](#outside-xcode-for-claude-code-or-codex)
   describes.
7. **Rerun the inventory.**

## Inventory without exporting

Health checks and setup inventory read the selected Xcode's bundled skill
files and never run `xcrun agent`:

```sh
X='<selected Xcode>/Contents'
grep -h -m1 '^name:' "$X"/PlugIns/IDEIntelligenceChat.framework/Versions/A/Resources/*.idechatprompttemplate
ls "$X"/PlugIns/*.framework/Versions/A/Resources/Skills/*/SKILL.md.packaged
```

Only the templates with a `name:` line are skills; the others are Xcode's own
prompts. A packaged skill's name is its folder's name. Some skills, such as the
accessibility and device-interaction ones in 27.1 and 27.2 beta, are compiled
into Xcode plug-ins and have no such file, so report the result as a partial
inventory for that build. To check an exposure, compare the recorded build with
the selected Xcode and the recomputed digest with the recorded one. An export
can hold more names than this listing, such as the compiled-in skills; only a
listed name missing from the export is drift. A link into an export in a root
that Xcode's agents also read is a duplicate for them unless the record holds
the person's acceptance; that includes `~/.claude/skills` while the import is
on and `skills` in a set override folder, both read as in step 1. A plug-in in
`~/Library/Developer/Xcode/CodingAssistant/AgentPlugins` whose `plugin.json`
lists a skill named in this listing, in a recorded export or in Xcode's own
`__xcode` copy is a duplicate exposure for both of Xcode's agents: report it
with that file's `importSource`. The `__xcode` folder names, read with `ls`,
include the compiled-in skills, as rendered by the Xcode that last ran Codex.

## Sources

- Apple: [WWDC26 session 278, Modernize your UIKit app](https://developer.apple.com/videos/play/wwdc2026/278/),
  [Extending and customizing agents](https://developer.apple.com/documentation/xcode/extending-and-customizing-agents),
  [Giving external agents access to Xcode](https://developer.apple.com/documentation/xcode/giving-external-agents-access-to-xcode)
- The selected Xcode's `usr/bin/agent`, `usr/bin/mcpbridge` help strings,
  bundled skill files and agent framework strings (`CLAUDE_CONFIG_DIR`,
  `CODEX_HOME`, `xcode-integration`, `ClaudeUserSkillImporter` with
  `IDEChatImportUserClaudeSettings`, the `CLAUDE_CONFIG_DIR` UserDefaults
  override near `IDEChatOverrideAgenticHomeDirectory`, the Plug-ins sheet's
  import options and `importSource`), and the `CodingAssistant` folders its
  agents used, read on
  2026-09-28 for Xcode 27.1 (27A9269) and 27.2 beta (27B5019j).
- [Claude Code: skills](https://code.claude.com/docs/en/skills) (locations,
  symlinked folders, additional directories, same-name precedence, live changes)
  and [the `.claude` directory](https://code.claude.com/docs/en/claude-directory)
  (`CLAUDE_CONFIG_DIR` moves every `~/.claude` path, `skills` included)
- [Codex: build skills](https://learn.chatgpt.com/docs/build-skills) (locations,
  symlinked folders, same-name skills),
  [config basics](https://learn.chatgpt.com/docs/config-file/config-basic)
  (an untrusted project skips project-local config, hooks and rules) and
  openai/codex `rust-v0.144.1`:
  [skill roots](https://github.com/openai/codex/blob/rust-v0.144.1/codex-rs/core-skills/src/loader.rs#L289-L316)
  (project layers read with `include_disabled` set, so an untrusted
  project's `.codex/skills` is a skill root, as
  [`skill_roots_from_layer_stack_includes_disabled_project_layers`](https://github.com/openai/codex/blob/rust-v0.144.1/codex-rs/core-skills/src/loader_tests.rs#L214)
  asserts),
  [link policy](https://github.com/openai/codex/blob/rust-v0.144.1/codex-rs/core-skills/src/loader.rs#L679-L682),
  [`skills.config` rules](https://github.com/openai/codex/blob/rust-v0.144.1/codex-rs/core-skills/src/config_rules.rs)
