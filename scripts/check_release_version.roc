#!/usr/bin/env roc
app [main!] {
	pf: platform "https://github.com/niclas-ahden/basic-cli/releases/download/0.31.0/Ff3fkK1TjYTVxMj9V21FP24ojTJXYk314Fbo1whBZ6Yf.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.10.2/7CdYzjBAJmprmnK45oTpmH6BXt76ZASN2Ck5uZQEoWsK.tar.zst",
}

import pf.Stdout
import weaver.Cli
import weaver.Opt
import weaver.Param
import Cargo
import CommandLine
import Files
import Process

## Synchronizes or checks the Cargo package version against a validated
## release version.
##
##     roc scripts/check_release_version.roc RELEASE_VERSION [--update] [--manifest-path PATH]
##
## Without `--update` it fails when the package version in Cargo.toml is not
## the release version. With `--update` it first writes the release version
## into `[package].version` and into the package's entry in the Cargo.lock
## next to the manifest, keeping every other byte and the line ends.
##
## `--manifest-path` defaults to Cargo.toml in the current folder, so run it
## from the repository root. Exits 1 on an error and 2 on a bad command line.
## `roc test scripts/check_release_version.roc` runs the tests at the bottom.
main! : _ => Try({}, _)
main! = |raw_args| {
	args = CommandLine.read!(cli, raw_args)?
	Process.finish!(check_release_version!(args.release_version, args.manifest_path ?? "Cargo.toml", args.update))
}

cli = Cli.finish_without_validating(
	{
		update: Opt.flag({ short: "", long: "update", help: "Write the release version into Cargo.toml and Cargo.lock first." }),
		manifest_path: Opt.maybe_str({ short: "", long: "manifest-path", help: "The Cargo.toml, the one in the current folder by default." }),
		release_version: Param.str({ name: "release-version", help: "The validated release version.", default: NoDefault }),
	}.Cli,
	CommandLine.config({ name: "check_release_version.roc", description: "Check the Cargo package version against a release version, or with --update set it." }),
)

check_release_version! : Str, Str, Bool => Try({}, [Failed(Str)])
check_release_version! = |release_version, manifest_path, update| {
	if update {
		{ name, .. } = cargo_package!(manifest_path)?
		manifest = Files.read_text!(manifest_path)?
		Files.write_text!(manifest_path, update_manifest(manifest, manifest_path, release_version)?)?
		lock_path = Files.sibling(manifest_path, "Cargo.lock")
		lock = Files.read_text!(lock_path)?
		Files.write_text!(lock_path, update_lock(lock, lock_path, name, release_version)?)?
	}
	{ version, .. } = cargo_package!(manifest_path)?
	if version != release_version {
		return Err(Failed(mismatch(version, release_version)))
	}
	Stdout.line!("Cargo package version ${version} matches the release version") ?? {}
	Ok({})
}

mismatch : Str, Str -> Str
mismatch = |package_version, release_version|
	"release version mismatch: Cargo package version is ${package_version}, but the validated release version is ${release_version}"

# Editing the manifest and the lockfile

## A `version = ...` line with the release version as its value. The key
## keeps its spacing and the line its line end.
replace_version_line : Str, Str -> Try(Str, [Failed(Str)])
replace_version_line = |line, release_version|
	match line.split_first("=") {
		Ok({ before, .. }) if before.trim() == "version" => Ok("${before}= \"${release_version}\"${line_end(line)}")
		_ => Err(Failed("invalid Cargo version line"))
	}

line_end : Str -> Str
line_end = |line|
	if (line.ends_with("\r\n")) "\r\n" else if (line.ends_with("\n")) "\n" else ""

## The key of a `key = value` line, without spacing. A line without `=` is
## its own key.
key_of : Str -> Str
key_of = |line|
	match line.split_first("=") {
		Ok({ before, .. }) => before.trim()
		Err(_) => line.trim()
	}

## The manifest with the first `version` of its `[package]` section set.
update_manifest : Str, Str, Str -> Try(Str, [Failed(Str)])
update_manifest = |manifest, manifest_path, release_version| {
	lines = lines_with_ends(manifest)
	var $in_package = False
	var $index = 0
	for line in lines {
		stripped = line.trim()
		if stripped.starts_with("[") and stripped.ends_with("]") {
			$in_package = stripped == "[package]"
		} else if $in_package and stripped.starts_with("version") and key_of(line) == "version" {
			replaced = replace_version_line(line, release_version)?
			return Ok(Str.join_with(lines.set($index, replaced) ?? lines, ""))
		}
		$index = $index + 1
	}
	Err(Failed("could not find [package].version in ${manifest_path}"))
}

## The lockfile with the version of the local package `name` set: the one
## `[[package]]` entry with that name and no `source`.
update_lock : Str, Str, Str, Str -> Try(Str, [Failed(Str)])
update_lock = |lock, lock_path, name, release_version| {
	lines = lines_with_ends(lock)
	starts = lines.map_with_index(|line, index| (line, index)).keep_if(|(line, _)| line.trim() == "[[package]]").map(|(_, index)| index)
	ends = starts.drop_first(1).append(lines.len())
	version_lines = starts.map2(ends, |start, end| (start, end)).join_map(
		|(start, end)| {
			block = lines.sublist({ start, len: end - start })
			is_local = !block.any(|line| line.trim().starts_with("source ="))
			is_named = block.any(|line| line.trim() == "name = \"${name}\"")
			if is_local and is_named {
				block.map_with_index(|line, offset| (line, start + offset)).keep_if(|(line, _)| key_of(line) == "version").map(|(_, index)| index)
			} else {
				[]
			}
		},
	)
	match version_lines {
		[index] => {
			line = lines.get(index) ?? ""
			replaced = replace_version_line(line, release_version)?
			Ok(Str.join_with(lines.set(index, replaced) ?? lines, ""))
		}
		_ => Err(Failed("expected one local ${name} package in ${lock_path}, found ${version_lines.len().to_str()}"))
	}
}

## The lines of a text, each with its line end.
lines_with_ends : Str -> List(Str)
lines_with_ends = |text| {
	parts = text.split_on("\n")
	last = parts.len() - 1
	parts.map_with_index(|part, index| if (index < last) "${part}\n" else part).drop_if(|part| part.is_empty())
}

# Cargo

## The name and version of the package whose manifest this is.
cargo_package! : Str => Try({ name : Str, version : Str }, [Failed(Str)])
cargo_package! = |manifest_path| {
	resolved = (Files.canonical!(manifest_path) ?? manifest_path)
	metadata = Cargo.metadata!(["--no-deps", "--manifest-path", resolved])?
	for pkg in metadata.crates {
		if (Files.canonical!(pkg.manifest_path) ?? pkg.manifest_path) == resolved {
			return Ok({ name: pkg.name, version: pkg.version })
		}
	}
	Err(Failed("cargo metadata did not contain the package at ${resolved}"))
}

# Tests

manifest_fixture : Str, Str -> Str
manifest_fixture = |version, newline|
	"[package]\nname = \"version-check-fixture\"\nversion = \"${version}\"\nedition = \"2021\"\n".replace_each("\n", newline)

lock_fixture : Str, Str -> Str
lock_fixture = |version, newline|
	"# This file is automatically @generated by Cargo.\n# It is not intended for manual editing.\nversion = 4\n\n[[package]]\nname = \"version-check-fixture\"\nversion = \"${version}\"\n".replace_each("\n", newline)

# The update writes the release version into the manifest and the lockfile
# and keeps their Windows line ends.
expect update_manifest(manifest_fixture("0.21.0-rc4", "\r\n"), "Cargo.toml", "0.21.0-rc5") == Ok(manifest_fixture("0.21.0-rc5", "\r\n"))
expect update_lock(lock_fixture("0.21.0-rc4", "\r\n"), "Cargo.lock", "version-check-fixture", "0.21.0-rc5") == Ok(lock_fixture("0.21.0-rc5", "\r\n"))
expect update_manifest(manifest_fixture("0.21.0-rc4", "\n"), "Cargo.toml", "0.21.0") == Ok(manifest_fixture("0.21.0", "\n"))

# Only `[package].version` changes, not a dependency's or a workspace key.
expect {
	manifest = "[workspace]\nversion = \"9\"\n\n[package]\nname = \"x\"\nversion.workspace = true\nversion  = \"1.0.0\" # pinned\nversion = \"2\"\n\n[dependencies]\nfoo = { version = \"1\" }\n"
	update_manifest(manifest, "Cargo.toml", "1.1.0") == Ok("[workspace]\nversion = \"9\"\n\n[package]\nname = \"x\"\nversion.workspace = true\nversion  = \"1.1.0\"\nversion = \"2\"\n\n[dependencies]\nfoo = { version = \"1\" }\n")
}
expect update_manifest("[dependencies]\nversion = \"1\"\n", "Cargo.toml", "2") == Err(Failed("could not find [package].version in Cargo.toml"))

# Only the local package's lock entry changes, not a registry one of the
# same name.
expect {
	lock = "version = 4\n\n[[package]]\nname = \"x\"\nversion = \"1.0.0\"\nsource = \"registry+https://github.com/rust-lang/crates.io-index\"\n\n[[package]]\nname = \"x\"\nversion = \"0.1.0\"\ndependencies = [\n \"y\",\n]\n\n[[package]]\nname = \"y\"\nversion = \"0.1.0\"\n"
	update_lock(lock, "Cargo.lock", "x", "0.2.0") == Ok(lock.replace_each("name = \"x\"\nversion = \"0.1.0\"", "name = \"x\"\nversion = \"0.2.0\""))
}
expect update_lock("version = 4\n", "Cargo.lock", "x", "1") == Err(Failed("expected one local x package in Cargo.lock, found 0"))
expect update_lock("[[package]]\nname = \"x\"\nversion = \"1\"\n[[package]]\nname = \"x\"\nversion = \"2\"\n", "Cargo.lock", "x", "3") == Err(Failed("expected one local x package in Cargo.lock, found 2"))

# A version that differs is named in the error.
expect mismatch("0.21.0-rc4", "0.21.0") == "release version mismatch: Cargo package version is 0.21.0-rc4, but the validated release version is 0.21.0"

expect lines_with_ends("a\r\nb\n\nc") == ["a\r\n", "b\n", "\n", "c"]
expect lines_with_ends("a\n") == ["a\n"]
