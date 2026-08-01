#!/usr/bin/env python3
"""Emit a deterministic static catalog from a pinned upstream checkout.

This intentionally parses source with the standard library rather than importing the
SDK, so no provider, CLI, or credentials are involved in catalog generation.
"""
from __future__ import annotations

import argparse
import ast
import json
from pathlib import Path


def literal_all(path: Path) -> list[str]:
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(
            isinstance(target, ast.Name) and target.id == "__all__"
            for target in node.targets
        ):
            value = ast.literal_eval(node.value)
            if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
                raise ValueError(f"{path}: __all__ must be a literal list of strings")
            return value
    raise ValueError(f"{path}: no literal __all__ assignment")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    root = args.source
    tests = sorted(str(path.relative_to(root)) for path in (root / "tests").glob("*.py"))
    exports = [
        {"module": "claude_agent_sdk", "name": name}
        for name in literal_all(root / "src/claude_agent_sdk/__init__.py")
    ]
    catalog = {
        "schema_version": 1,
        "upstream": {
            "repository": "https://github.com/anthropics/claude-agent-sdk-python",
            "commit": args.commit,
        },
        "test_files": tests,
        "exports": exports,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(catalog, indent=2, sort_keys=True) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
