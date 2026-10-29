#!/usr/bin/env python3
"""Synchronize or check Cargo against a validated release version."""

import argparse
import json
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read_text(path: Path) -> str:
    with path.open("r", encoding="utf-8", newline="") as file:
        return file.read()


def write_text(path: Path, content: str) -> None:
    with path.open("w", encoding="utf-8", newline="") as file:
        file.write(content)


def replace_version_line(line: str, release_version: str) -> str:
    key, separator, _value = line.partition("=")
    if not separator or key.strip() != "version":
        raise RuntimeError("invalid Cargo version line")
    if line.endswith("\r\n"):
        newline = "\r\n"
    elif line.endswith("\n"):
        newline = "\n"
    else:
        newline = ""
    return f'{key}= "{release_version}"{newline}'


def update_cargo_package_version(manifest_path: Path, release_version: str) -> None:
    lines = read_text(manifest_path).splitlines(keepends=True)
    in_package_section = False
    updated = False

    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            in_package_section = stripped == "[package]"
        elif in_package_section and stripped.startswith("version"):
            if line.partition("=")[0].strip() != "version":
                continue
            lines[index] = replace_version_line(line, release_version)
            updated = True
            break

    if not updated:
        raise RuntimeError(f"could not find [package].version in {manifest_path}")

    write_text(manifest_path, "".join(lines))


def update_lockfile_package_version(
    lock_path: Path, package_name: str, release_version: str
) -> None:
    lines = read_text(lock_path).splitlines(keepends=True)
    package_starts = [
        index for index, line in enumerate(lines) if line.strip() == "[[package]]"
    ]
    package_starts.append(len(lines))
    matching_version_lines: list[int] = []

    for start, end in zip(package_starts, package_starts[1:]):
        block = lines[start:end]
        if any(line.strip().startswith("source =") for line in block):
            continue
        if f'name = "{package_name}"' not in (line.strip() for line in block):
            continue
        matching_version_lines.extend(
            start + offset
            for offset, line in enumerate(block)
            if line.partition("=")[0].strip() == "version"
        )

    if len(matching_version_lines) != 1:
        raise RuntimeError(
            f"expected one local {package_name} package in {lock_path}, "
            f"found {len(matching_version_lines)}"
        )

    version_line = matching_version_lines[0]
    lines[version_line] = replace_version_line(lines[version_line], release_version)
    write_text(lock_path, "".join(lines))


def cargo_package(manifest_path: Path) -> tuple[str, str]:
    manifest_path = manifest_path.resolve()
    result = subprocess.run(
        [
            "cargo",
            "metadata",
            "--no-deps",
            "--format-version",
            "1",
            "--manifest-path",
            str(manifest_path),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        diagnostic = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(f"cargo metadata failed: {diagnostic}")

    try:
        metadata = json.loads(result.stdout)
        package = next(
            package
            for package in metadata["packages"]
            if Path(package["manifest_path"]).resolve() == manifest_path
        )
        package_name = package["name"]
        package_version = package["version"]
        if not isinstance(package_name, str) or not isinstance(package_version, str):
            raise KeyError
        return package_name, package_version
    except (json.JSONDecodeError, KeyError, StopIteration) as error:
        raise RuntimeError(
            f"cargo metadata did not contain the package at {manifest_path}"
        ) from error


def cargo_package_version(manifest_path: Path) -> str:
    _package_name, package_version = cargo_package(manifest_path)
    return package_version


def check_release_version(
    release_version: str, manifest_path: Path, update: bool = False
) -> None:
    if update:
        package_name, _package_version = cargo_package(manifest_path)
        update_cargo_package_version(manifest_path, release_version)
        update_lockfile_package_version(
            manifest_path.with_name("Cargo.lock"), package_name, release_version
        )

    package_version = cargo_package_version(manifest_path)
    if package_version != release_version:
        raise RuntimeError(
            "release version mismatch: "
            f"Cargo package version is {package_version}, "
            f"but the validated release version is {release_version}"
        )

    print(f"Cargo package version {package_version} matches the release version")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("release_version", help="validated release version")
    parser.add_argument(
        "--update",
        action="store_true",
        help="update the Cargo package before verifying it",
    )
    parser.add_argument(
        "--manifest-path",
        type=Path,
        default=ROOT / "Cargo.toml",
        help="Cargo manifest to inspect (default: repository root Cargo.toml)",
    )
    args = parser.parse_args()

    try:
        check_release_version(args.release_version, args.manifest_path, args.update)
    except (OSError, RuntimeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
