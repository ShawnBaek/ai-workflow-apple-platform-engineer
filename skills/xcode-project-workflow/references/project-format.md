# Xcode project format

This reference extends the `xcode-project-workflow`
[project format gate](../SKILL.md#project-format-gate). It covers detecting a
container's format, editing and validating `project.xcproj`, converting
between formats, and moving a generator-owned project off its generator.

## Detect the format

Inspect the authoritative container without launching Xcode:

```sh
ls MyApp.xcodeproj
```

| Inside the `.xcodeproj` | Format | Source of truth |
| --- | --- | --- |
| `project.xcproj` | Xcode project format, JSON5 text with readable keys and far fewer object IDs (Xcode 27.2 or later) | the file itself |
| `project.pbxproj` | legacy property-list format | the file itself, unless a generator below owns it |
| `project.pbxproj` plus a repository `project.yml` (XcodeGen) or `Project.swift` (Tuist) that README, CI or scripts generate from | generated legacy project | the generator input |
| no `.xcodeproj`, only a documented generator input (a fresh clone) | generated legacy project, not yet generated | the generator input; generating it follows the gate's legacy generator rules |

A generator counts as the source of truth only when the repository documents
or runs it. A stray `project.yml` with no caller is an observation to report.

## Edit `project.xcproj`

- Edit the file as text. It is JSON5: trailing commas are part of the
  canonical form, so a strict JSON tool (`jq`, `JSONSerialization`,
  `plutil -convert`) cannot round-trip it. Never rewrite it through one.
- Express file membership the way the file already does: a `"kind": "group"`
  entry lists files with `target-membership`, while a synchronized folder is a
  single `"kind": "folder"` entry whose `target-membership` covers its contents.
  Keep new entries next to their siblings; the formatter fixes order and layout.
- A new target needs an `id`: `xcprojformatter` rejects a target without one
  (`Missing required value for key "id" at "/targets[0]"`). Use 24 uppercase
  hexadecimal characters, unique in the file, as Xcode writes them. Products
  carry an `id` too; file and group entries do not need one.
- A file inside a synchronized folder needs no project edit at all.

## Validate with `xcprojformatter`

`xcprojformatter` is Apple's open-source formatter and validator for
`project.xcproj`, built on the
[`XcodeProjectFormat`](https://github.com/apple/xcode-project-format) library
(Apache-2.0, `XCSchema` types). Xcode 27.2 and later ship it in
`Contents/Developer/usr/bin`, so run it through `xcrun` with the
[selected Xcode](xcode-selection.md). Run the four checks in order after every
edit, conversion or merge that touches `project.xcproj`; stop at the first
failure:

```sh
P=MyApp.xcodeproj

# 1. Parse and type check: exit 0, or exit 255 with the error
#    (for example "Expected an instance of string but an instance integer was specified").
xcrun xcprojformatter "$P" > /dev/null

# 2. Canonical layout: no output means canonical.
xcrun xcprojformatter "$P" | diff -u "$P/project.xcproj" -

# 3. Xcode loads the container: targets, configurations and schemes are listed.
xcodebuild -list -project "$P"

# 4. Build through `xcodebuild` (see that skill) for the affected scheme.
```

- Check 1 does not reject unknown or misspelled keys: the formatter drops
  them silently and exits 0. Check 2 is where that shows up.
- A check 2 diff that only moves, reorders or reindents content is a
  formatting finding: fix it with `xcrun xcprojformatter --update "$P"` and
  review the result. A diff that removes a key or value means the formatter
  did not recognise it, so the edit is wrong. Fix the edit by hand; never let
  `--update` delete it.
- Checks 1 and 2 do not verify that referenced files exist. A missing file
  passes both and `xcodebuild -list`, then fails the build with "Build input
  file cannot be found", so check 4 stays required.
- On a machine without Xcode 27.2, such as a Linux CI job, run the same tool
  from the open-source package, pinned to a release tag:

  ```sh
  git clone --depth 1 --branch 0.1.0 https://github.com/apple/xcode-project-format
  swift run --package-path xcode-project-format xcprojformatter "$P" > /dev/null
  ```

  The bundled and package builds can differ while the format is new. When
  they disagree, the selected Xcode's copy wins for the developer's project;
  report the difference.

## Convert between formats

`xcodebuild -convert-project` rewrites the container in place:

```sh
# Legacy project.pbxproj -> project.xcproj ("xcproj" is accepted as an alias).
xcodebuild -project "$P" -convert-project "Xcode Project"

# Back to a legacy project.pbxproj. The format names the oldest Xcode that
# opens the result: pick the one that matches the oldest Xcode in use
# ("Xcode 27.0" for 27.0 or 27.1, "Xcode 26.3" or older for earlier releases).
xcodebuild -project "$P" -convert-project "Xcode 27.0"
```

An unknown format name prints the accepted list. Conversion replaces one file
with the other, and an Xcode older than 27.2 cannot open the result, so it
needs the gate's approval. Before converting, record the Xcode versions that
open this project: teammates, every CI lane (a compatibility-floor lane below
27.2 blocks conversion), and Xcode Cloud workflows. After converting, run the
four checks, then compare `xcodebuild -showBuildSettings -json` for each
scheme with the output recorded before conversion; any difference other than
ordering is a conversion defect to report, not to hand-correct.

## Move a generated project to `project.xcproj`

When XcodeGen or Tuist owns a legacy project and the developer approves the
move:

1. Close the project in Xcode. Generate once from the current generator input
   so the starting point matches the declared source of truth; record the diff.
2. Convert with `-convert-project "Xcode Project"` and run the checks above.
3. Commit `project.xcproj` as the source of truth. Remove the generator input
   and its CI, script and README callers, and stop ignoring the
   `.xcodeproj` in `.gitignore`, in the same reviewed change.
4. Reopen the same container in a new Xcode session and build the affected
   schemes.

Without that approval, leave the generator in place and follow the gate's
legacy generator rules.
