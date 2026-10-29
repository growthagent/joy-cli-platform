#!/usr/bin/env python3
"""Tests for check_roc_pin.py."""

import json
import tempfile
import unittest
from pathlib import Path

from scripts.check_roc_pin import check

COMMIT = "54283d46d5bd1741dbe677f54ef4646eee4623ff"
OTHER = "b797cda76e77b9e514c2192ca6513d0ba9a39070"


def write(root: Path, name: str, content: str) -> None:
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def fixture(root: Path, flake: str, locked: str, workflow: str) -> None:
    write(root, "flake.nix", f'    roc-src.url = "github:roc-lang/roc/{flake}?dir=src";\n')
    write(root, "flake.lock", json.dumps({"nodes": {"roc-src": {"locked": {"rev": locked}}}}))
    write(root, ".github/workflows/ci.yml", workflow)


class CheckRocPinTests(unittest.TestCase):
    def problems(self, flake: str, locked: str, workflow: str = "      - uses: ./.github/actions/setup-roc-pinned\n") -> list[str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture(root, flake, locked, workflow)
            return check(root)

    def test_matching_pins_pass(self) -> None:
        self.assertEqual(self.problems(COMMIT, COMMIT), [])

    def test_stale_lock_fails(self) -> None:
        self.assertTrue(self.problems(COMMIT, OTHER))

    def test_workflow_nightly_fails(self) -> None:
        self.assertTrue(self.problems(COMMIT, COMMIT, "          nightly-tag: nightly-2026-10-12-2664a27\n"))

    def test_missing_pin_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write(root, "flake.nix", "{}\n")
            self.assertTrue(check(root))


if __name__ == "__main__":
    unittest.main()
