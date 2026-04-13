#!/usr/bin/env python3

from __future__ import annotations

import shutil
import sys
from pathlib import Path


AGREEMENT_FILES = (
    "privacy-policy.md",
    "user-agreement.md",
)


def sync_agreements(target_dir: Path) -> None:
    repo_root = Path(__file__).resolve().parents[1]
    docs_dir = repo_root / "docs"
    target_dir.mkdir(parents=True, exist_ok=True)

    for filename in AGREEMENT_FILES:
        source = docs_dir / filename
        target = target_dir / filename
        if not source.is_file():
            raise FileNotFoundError(f"Missing agreement source: {source}")
        shutil.copyfile(source, target)
        print(f"[sync_agreements] {source} -> {target}")


def main() -> int:
    if len(sys.argv) < 2:
        print("Usage: sync_agreements.py <target_dir> [<target_dir> ...]", file=sys.stderr)
        return 1

    for raw_target in sys.argv[1:]:
        sync_agreements(Path(raw_target).resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
