#!/usr/bin/env python3
"""Reverify one reserved external action immediately before dispatch."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import check_authorization


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ledger", type=Path, required=True)
    parser.add_argument("--reservation-id", required=True)
    parser.add_argument("--run-root", type=Path, required=True)
    parser.add_argument("--harness", type=Path, required=True)
    parser.add_argument("--coordinator-state", type=Path, required=True)
    parser.add_argument("--health-report", type=Path, required=True)
    parser.add_argument("--request", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        harness = check_authorization.resource_coordinator.load_trusted_harness(
            arguments.harness
        )
    except (
        OSError,
        json.JSONDecodeError,
        check_authorization.resource_coordinator.CoordinatorError,
    ) as error:
        print(json.dumps({"verified": False, "errors": [str(error)], "dispatch": None}))
        return 2
    errors, dispatch = check_authorization.verify_reserved_action(
        arguments.ledger,
        arguments.reservation_id,
        arguments.run_root,
        arguments.coordinator_state,
        harness.get("resource_coordinator") if isinstance(harness, dict) else None,
        arguments.health_report,
        arguments.harness,
        request_path=arguments.request,
    )
    print(json.dumps(
        {"verified": not errors, "errors": errors, "dispatch": dispatch},
        indent=2,
        sort_keys=True,
    ))
    return 0 if not errors else 2


if __name__ == "__main__":
    raise SystemExit(main())
