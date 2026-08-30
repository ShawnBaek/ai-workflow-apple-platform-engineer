#!/usr/bin/env python3
"""Copy a JSON template with a valid absolute file URI for its installed schema."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile
from typing import Any

import check_authorization


class MaterializeError(ValueError):
    pass


def _regular_json(path: Path, label: str) -> dict[str, Any]:
    if not path.is_absolute() or path.is_symlink() or not path.is_file():
        raise MaterializeError(f"{label} must be an absolute regular non-symlink file")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise MaterializeError(f"{label} is not readable JSON") from error
    if not isinstance(value, dict):
        raise MaterializeError(f"{label} must contain a JSON object")
    return value


def materialize(
    template_path: Path,
    schema_path: Path,
    output_path: Path,
    *,
    replace: bool = False,
) -> dict[str, str]:
    template = _regular_json(template_path, "template")
    schema = _regular_json(schema_path, "schema")
    if not output_path.is_absolute():
        raise MaterializeError("output must be an absolute path")
    parent = output_path.parent
    if not parent.is_dir() or parent.is_symlink():
        raise MaterializeError("output parent must exist and must not be a symlink")
    if output_path.is_symlink() or (output_path.exists() and not output_path.is_file()):
        raise MaterializeError("output must be a regular non-symlink file")
    if output_path.exists() and not replace:
        raise MaterializeError("output already exists; pass --replace for an explicit update")

    canonical_schema = schema_path.resolve(strict=True)
    document = dict(template)
    document["$schema"] = canonical_schema.as_uri()
    if "contract_schema_id" in document:
        schema_id = schema.get("$id")
        if not isinstance(schema_id, str) or not schema_id:
            raise MaterializeError("schema must provide a stable non-empty $id")
        document["contract_schema_id"] = schema_id
    if "contract_schema_sha256" in document:
        document["contract_schema_sha256"] = (
            "sha256:" + hashlib.sha256(canonical_schema.read_bytes()).hexdigest()
        )
    validation_errors = check_authorization._schema_errors(document, schema)
    if validation_errors:
        raise MaterializeError(
            "materialized document failed its installed schema: "
            + "; ".join(sorted(set(validation_errors)))
        )

    descriptor, temporary = tempfile.mkstemp(
        prefix=f".{output_path.name}.", dir=os.fspath(parent)
    )
    try:
        os.fchmod(descriptor, stat.S_IRUSR | stat.S_IWUSR)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(document, handle, indent=2, sort_keys=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, output_path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return {
        "output_path": str(output_path.resolve(strict=True)),
        "schema_uri": canonical_schema.as_uri(),
        "contract_schema_id": str(schema.get("$id", "")),
        "contract_schema_sha256": "sha256:"
        + hashlib.sha256(canonical_schema.read_bytes()).hexdigest(),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--template", type=Path, required=True)
    parser.add_argument("--schema", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--replace", action="store_true")
    arguments = parser.parse_args()
    try:
        result = materialize(
            arguments.template,
            arguments.schema,
            arguments.output,
            replace=arguments.replace,
        )
    except MaterializeError as error:
        print(json.dumps({"status": "blocked", "reason": str(error)}, sort_keys=True))
        return 2
    print(json.dumps({"status": "ok", **result}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
