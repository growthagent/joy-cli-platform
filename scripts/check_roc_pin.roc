#!/usr/bin/env roc
app [main!] {
	pf: platform "https://github.com/niclas-ahden/basic-cli/releases/download/0.31.0/Ff3fkK1TjYTVxMj9V21FP24ojTJXYk314Fbo1whBZ6Yf.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.10.2/7CdYzjBAJmprmnK45oTpmH6BXt76ZASN2Ck5uZQEoWsK.tar.zst",
}

import pf.Path
import pf.Stderr
import pf.Stdout
import weaver.Builder
import weaver.Cli
import CommandLine
import Files
import RocPin

## Checks that the Roc commit pinned in flake.nix is the one flake.lock locks.
##
## The devshell builds the compiler that flake.lock locks, and the workflows
## install a build of it with `uses: niclas-ahden/roc-builds@<sha>`, so the url
## in flake.nix is the only other place that names it. A downloaded nightly
## anywhere in the workflows or the flake would be a second compiler.
##
## Run it from the repository root:
##
##     roc scripts/check_roc_pin.roc
##
## It exits 1 and lists the problems when the pins are not in sync.
## `roc test scripts/check_roc_pin.roc` runs the tests at the bottom.
main! : _ => Try({}, _)
main! = |raw_args| {
	_ = CommandLine.read!(cli, raw_args)?
	problems = match read_sources!() {
		Ok(sources) => check(sources)
		Err(Notice(message)) => [message]
	}
	if problems.is_empty() {
		Stdout.line!("Roc pins are in sync.") ?? {}
		Ok({})
	} else {
		Stderr.line!("Roc pins are not in sync:") ?? {}
		for problem in problems {
			Stderr.line!("  ${problem}") ?? {}
		}
		Err(Exit(1))
	}
}

cli = Cli.finish_without_validating(Builder.from_arg_parser(|args| Ok({ data: {}, remaining_args: args })), CommandLine.config({ name: "check_roc_pin.roc", description: "Check that the Roc commit flake.nix pins is the one flake.lock locks." }))

## The files the check reads: flake.nix, flake.lock when there is one, and
## every workflow by its path.
Sources : { flake : Str, lock : Try(Str, [Missing]), workflows : List((Str, Str)) }

read_sources! : () => Try(Sources, [Notice(Str)])
read_sources! = || {
	flake = Files.read_text!("flake.nix") ? |_| Notice("flake.nix: not found, run this from the repository root")
	lock = Files.read_text!("flake.lock").map_err(|_| Missing)
	names = workflow_names!()?
	workflows = names.fold_try!([], |all, path| Ok(all.append((path, Files.read_text!(path) ? |_| Notice("${path}: could not be read")))))?
	Ok({ flake, lock, workflows })
}

## The workflow files, sorted, as `.github/workflows/*.yml` matches them.
workflow_names! : () => Try(List(Str), [Notice(Str)])
workflow_names! = || {
	folder = ".github/workflows"
	if !(Path.utf8(folder).is_dir!() ?? False) {
		return Ok([])
	}
	Files.files_in!(folder, ".yml").map_err(|_| Notice("${folder}: could not be listed"))
}

## Every problem with the pins, or none when they are in sync.
check : Sources -> List(Str)
check = |sources|
	match RocPin.flake_pin(sources.flake) {
		Err(NoPin) => ["flake.nix: no roc-src commit pin found"]
		Ok(pinned) => {
			locked = match sources.lock {
				Ok(text) => locked_rev(text)
				Err(Missing) => Err(Unlocked)
			}
			mismatch = match locked {
				Ok(rev) if rev == pinned => []
				Ok(rev) => ["flake.nix pins ${pinned} but flake.lock locks ${rev}, run `nix flake lock`"]
				Err(Unlocked) => ["flake.nix pins ${pinned} but flake.lock locks no roc-src commit, run `nix flake lock`"]
			}
			nightlies = [("flake.nix", sources.flake)]
				.concat(sources.workflows)
				.keep_if(|(_, text)| uses_nightly(text))
				.map(|(path, _)| "${path}: uses a Roc nightly, not the pinned commit")
			mismatch.concat(nightlies)
		}
	}

uses_nightly : Str -> Bool
uses_nightly = |text| text.contains("nightly-tag:") or text.contains("rocpkgs.")

Locked := { rev : Str ?? "" }.{
	parser_for : _
}

LockNode := { locked : Locked ?? Locked.{ rev: "" } }.{
	parser_for : _
}

Lock : { nodes : Dict(Str, LockNode) }

## The commit flake.lock locks for roc-src.
locked_rev : Str -> Try(Str, [Unlocked])
locked_rev = |text| {
	parsed : Try(Lock, _)
	parsed = Json.parse(text)
	match parsed {
		Ok(lock) =>
			match lock.nodes.get("roc-src") {
				Ok(node) if node.locked.rev != "" => Ok(node.locked.rev)
				_ => Err(Unlocked)
			}
		Err(_) => Err(Unlocked)
	}
}

# Tests

commit : Str
commit = "54283d46d5bd1741dbe677f54ef4646eee4623ff"

other : Str
other = "b797cda76e77b9e514c2192ca6513d0ba9a39070"

pinned_workflow : Str
pinned_workflow = "      - uses: niclas-ahden/roc-builds@5bc987dcfa80307d7a4097bd5e64c6e30ccd7760 # v1\n"

fixture : Str, Str, Str -> Sources
fixture = |flake, locked, workflow| {
	flake: "    roc-src.url = \"github:roc-lang/roc/${flake}?dir=src\";\n",
	lock: Ok("{\"nodes\": {\"root\": {\"inputs\": {\"roc-src\": \"roc-src\"}}, \"roc-src\": {\"locked\": {\"rev\": \"${locked}\", \"type\": \"github\"}}}, \"version\": 7}"),
	workflows: [(".github/workflows/ci.yml", workflow)],
}

# Matching pins pass.
expect check(fixture(commit, commit, pinned_workflow)) == []

# A stale lock fails.
expect check(fixture(commit, other, pinned_workflow)) == ["flake.nix pins ${commit} but flake.lock locks ${other}, run `nix flake lock`"]

# A nightly in a workflow fails.
expect check(fixture(commit, commit, "          nightly-tag: nightly-2026-10-12-2664a27\n")) == [".github/workflows/ci.yml: uses a Roc nightly, not the pinned commit"]

# A missing pin fails.
expect check({ flake: "{}\n", lock: Err(Missing), workflows: [] }) == ["flake.nix: no roc-src commit pin found"]

# A missing lock fails.
expect check({ flake: fixture(commit, commit, "").flake, lock: Err(Missing), workflows: [] }) == ["flake.nix pins ${commit} but flake.lock locks no roc-src commit, run `nix flake lock`"]
