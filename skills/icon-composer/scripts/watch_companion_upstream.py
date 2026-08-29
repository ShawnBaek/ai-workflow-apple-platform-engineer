#!/usr/bin/env python3
"""Compare a reference-only companion upstream and optionally reconcile one Issue."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


API = "https://api.github.com"
MARKER_PREFIX = "<!-- ios-experts-companion-upstream:"


def load_manifest(path: Path) -> dict[str, Any]:
    manifest = json.loads(path.read_text(encoding="utf-8"))
    upstream = manifest.get("upstream", {})
    integration = manifest.get("integration", {})
    if upstream.get("visibility") != "public":
        raise ValueError("companion watcher supports public upstreams only")
    if integration.get("mode") != "reference-only":
        raise ValueError("companion upstream must remain reference-only")
    if integration.get("execute_upstream") is not False or integration.get("vendored_files") != []:
        raise ValueError("companion watcher cannot execute or vendor upstream content")
    if integration.get("auto_merge") is not False:
        raise ValueError("companion watcher cannot enable auto-merge")
    return manifest


def compare(manifest: dict[str, Any], observed_revision: str) -> dict[str, Any]:
    reviewed = manifest["upstream"]["reviewed_revision"]
    changed = observed_revision != reviewed
    repository = manifest["upstream"]["repository"]
    return {
        "repository": repository,
        "reviewed_revision": reviewed,
        "observed_revision": observed_revision,
        "changed": changed,
        "action": "create_or_update_review_issue" if changed else "none",
        "copy_or_execute_upstream": False,
        "auto_merge": False,
    }


class GitHub:
    def __init__(self, token: str):
        if not token:
            raise ValueError("GITHUB_TOKEN is required for Issue reconciliation")
        self.headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "ios-experts-companion-watch",
        }

    def request(self, method: str, path: str, body: dict[str, Any] | None = None) -> Any:
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(API + path, data=data, headers=self.headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                return json.loads(response.read().decode())
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace")[:500]
            raise RuntimeError(f"GitHub API {method} {path} failed: {error.code} {detail}") from error


def _marker(repository: str) -> str:
    return f"{MARKER_PREFIX}{repository} -->"


def _issue_body(manifest: dict[str, Any], observed_revision: str) -> str:
    upstream = manifest["upstream"]
    repository = upstream["repository"]
    reviewed = upstream["reviewed_revision"]
    branch = upstream["default_branch"]
    source_paths = "\n".join(f"- `{item['path']}`" for item in manifest["sources"])
    return f"""{_marker(repository)}

The public reference-only companion upstream changed.

- Upstream: `https://github.com/{repository}`
- Branch: `{branch}`
- Last reviewed: `{reviewed}`
- Observed: `{observed_revision}`
- Compare: `https://github.com/{repository}/compare/{reviewed}...{observed_revision}`
- License state: `{manifest['license']['status']}`
- Consumer: `{manifest['integration']['consumer_skill']}`

Review surface:
{source_paths}

Do not copy or execute upstream code, assets, or prose. Review the exact commit,
re-express only general Apple-icon guidance, update provenance, run focused
contract tests, and deliver through the normal Issue-to-PR harness. Auto-merge
and changes to the upstream repository are out of scope.
"""


def reconcile_issue(
    manifest: dict[str, Any],
    target_repository: str,
    client: GitHub,
) -> dict[str, Any]:
    upstream = manifest["upstream"]
    if target_repository != manifest["integration"].get("consumer_repository"):
        raise ValueError("Issue target does not match the pinned consumer repository")
    owner, repository = upstream["repository"].split("/", 1)
    metadata = client.request("GET", f"/repos/{owner}/{repository}")
    if metadata.get("private") is not False or metadata.get("visibility") != "public":
        raise RuntimeError("companion upstream is no longer public")
    if metadata.get("default_branch") != upstream["default_branch"]:
        raise RuntimeError("companion upstream default branch drifted from the manifest")
    reviewed_revision = upstream["reviewed_revision"]
    reviewed_commit = client.request(
        "GET", f"/repos/{owner}/{repository}/commits/{reviewed_revision}"
    )
    if reviewed_commit.get("sha") != reviewed_revision:
        raise RuntimeError("reviewed upstream revision no longer resolves exactly")
    reviewed_tree = reviewed_commit.get("commit", {}).get("tree", {}).get("sha")
    if reviewed_tree != upstream["reviewed_tree"]:
        raise RuntimeError("reviewed upstream tree drifted from the manifest")
    tree = client.request(
        "GET", f"/repos/{owner}/{repository}/git/trees/{reviewed_tree}?recursive=1"
    )
    blobs = {
        item.get("path"): item.get("sha")
        for item in tree.get("tree", [])
        if item.get("type") == "blob"
    }
    for source in manifest["sources"]:
        if blobs.get(source["path"]) != source["blob_sha"]:
            raise RuntimeError(f"reviewed source blob drifted: {source['path']}")
    branch = urllib.parse.quote(metadata["default_branch"], safe="")
    commit = client.request("GET", f"/repos/{owner}/{repository}/commits/{branch}")
    observed = commit.get("sha", "")
    if len(observed) != 40:
        raise RuntimeError("upstream HEAD did not resolve to a full commit SHA")
    result = compare(manifest, observed)
    if not result["changed"]:
        return {**result, "issue_action": "none"}
    target_owner, target_name = target_repository.split("/", 1)
    issues: list[dict[str, Any]] = []
    for page in range(1, 11):
        batch = client.request(
            "GET",
            f"/repos/{target_owner}/{target_name}/issues?state=open&per_page=100&page={page}",
        )
        issues.extend(batch)
        if len(batch) < 100:
            break
    else:
        raise RuntimeError("too many open Issues to reconcile the upstream marker safely")
    marker = _marker(upstream["repository"])
    existing = next(
        (
            issue
            for issue in issues
            if "pull_request" not in issue and marker in (issue.get("body") or "")
        ),
        None,
    )
    title = f"Review IconGen upstream {observed[:12]}"
    body = _issue_body(manifest, observed)
    if existing:
        issue = client.request(
            "PATCH",
            f"/repos/{target_owner}/{target_name}/issues/{existing['number']}",
            {"title": title, "body": body},
        )
        action = "updated"
    else:
        issue = client.request(
            "POST",
            f"/repos/{target_owner}/{target_name}/issues",
            {"title": title, "body": body},
        )
        action = "created"
    return {**result, "issue_action": action, "issue_url": issue.get("html_url")}


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    root.add_argument("--manifest", type=Path, required=True)
    commands = root.add_subparsers(dest="command", required=True)
    check = commands.add_parser("check")
    check.add_argument("--observed-revision", required=True)
    sync = commands.add_parser("sync-issue")
    sync.add_argument("--target-repository", required=True)
    return root


def main() -> int:
    arguments = parser().parse_args()
    manifest = load_manifest(arguments.manifest)
    if arguments.command == "check":
        result = compare(manifest, arguments.observed_revision)
    else:
        result = reconcile_issue(
            manifest,
            arguments.target_repository,
            GitHub(os.environ.get("GITHUB_TOKEN", "")),
        )
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
