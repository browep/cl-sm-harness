#!/usr/bin/env python3
"""Credential-free reference export entrypoint for future contract vectors.

Phase 2 exports the immutable source catalog only. Later phases may add narrowly
scoped, redacted probes here; this script must never import credentials or run a
live Claude request.
"""
from __future__ import annotations

import argparse
import shutil
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("catalog", type=Path, help="catalog baked into the reference image")
    parser.add_argument("output", type=Path, help="destination mounted by Compose")
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(args.catalog, args.output)


if __name__ == "__main__":
    main()
