#!/usr/bin/env python3
"""Check that the Roc commit pinned in flake.nix is the one flake.lock locks.

The workflows build the compiler that flake.lock locks (see
.github/actions/setup-roc-pinned), and the devshell builds the same one, so
the url in flake.nix is the only other place that names it. A downloaded
nightly anywhere in the workflows or the flake would be a second compiler.
"""

import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

FLAKE_PIN = re.compile(r'roc-src\.url\s*=\s*"github:roc-lang/roc/([0-9a-f]{40})\?dir=src"')
NIGHTLY = re.compile(r"nightly-tag:|rocpkgs\.")


def check(root: Path) -> list[str]:
    flake = (root / "flake.nix").read_text(encoding="utf-8")
    match = FLAKE_PIN.search(flake)
    if match is None:
        return ["flake.nix: no roc-src commit pin found"]
    lock = json.loads((root / "flake.lock").read_text(encoding="utf-8"))
    locked = lock.get("nodes", {}).get("roc-src", {}).get("locked", {}).get("rev")
    problems = []
    if locked != match[1]:
        problems.append(f"flake.nix pins {match[1]} but flake.lock locks {locked}, run `nix flake lock`")
    for path in [root / "flake.nix", *sorted(root.glob(".github/workflows/*.yml"))]:
        if NIGHTLY.search(path.read_text(encoding="utf-8")):
            problems.append(f"{path.relative_to(root).as_posix()}: uses a Roc nightly, not the pinned commit")
    return problems


def main() -> int:
    problems = check(ROOT)
    if problems:
        print("Roc pins are not in sync:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1
    print("Roc pins are in sync.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
