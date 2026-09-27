# Version Source Detection and Verification

Read this when a project has more than one apparent version value or includes extensions or a watch app.

## Resolve before editing

For the target and configuration being changed, inspect in this order:

1. project generator input such as `project.yml` or an equivalent spec;
2. included `.xcconfig` settings and their precedence;
3. Xcode project build settings, including conditional settings;
4. `Info.plist` substitutions or literal values.

Record whether `CFBundleShortVersionString` and `CFBundleVersion` expand from build settings or are literal. A literal `Info.plist` may be authoritative only when no higher project convention supplies it. Do not change a generated `.pbxproj` and generator input together. An embedded extension or watch app that sets its own value must still end with its containing app's values; report that per-target copy as part of the change instead of leaving it behind.

## Effective-value proof

Use the same project container, scheme/target, and configuration that the developer uses. If a build is appropriate and authorized, use its resulting app or extension bundle as the final evidence; otherwise report that only source/effective-setting inspection was performed. Compare the resolved marketing and build values for every affected bundle, not just the main application; each embedded extension and watch app must equal its containing app.

`agvtool` is appropriate only for a project already configured for Apple Generic Versioning. Confirm its existing setting and scope first; its use must not overwrite conditional, target-specific, or generator-owned values. In Xcode 27.1 and 27.2 beta, `agvtool new-marketing-version` never sets `MARKETING_VERSION`: it rewrites the `CFBundleShortVersionString` string in each file named by `INFOPLIST_FILE`, and `new-version -all` does the same for `CFBundleVersion`. That turns a `$(MARKETING_VERSION)` or `$(CURRENT_PROJECT_VERSION)` substitution into a literal, and a generated `Info.plist` (`GENERATE_INFOPLIST_FILE = YES`) without that key in a file gets no marketing-version change at all.
