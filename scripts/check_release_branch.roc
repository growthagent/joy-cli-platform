#!/usr/bin/env roc
app [main!] {
	pf: platform "https://github.com/niclas-ahden/basic-cli/releases/download/0.31.0/Ff3fkK1TjYTVxMj9V21FP24ojTJXYk314Fbo1whBZ6Yf.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.10.2/7CdYzjBAJmprmnK45oTpmH6BXt76ZASN2Ck5uZQEoWsK.tar.zst",
}

import pf.Stderr
import weaver.Cli
import weaver.Opt
import CommandLine

## Keeps stable publications on the default branch and allows release
## candidates from any branch.
##
##     roc scripts/check_release_branch.roc --release-version 0.26.0-rc1 --ref-type branch --ref-name main --default-branch main
##
## Exits 1 when the release may not be published from that ref, and 2 when an
## option is missing. `roc test scripts/check_release_branch.roc` runs the
## tests at the bottom.
main! : _ => Try({}, _)
main! = |raw_args| {
	args = CommandLine.read!(cli, raw_args)?
	match check_release_branch(args.version, args.ref_type, args.ref_name, args.default_branch) {
		Ok({}) => Ok({})
		Err(Refused(message)) => {
			Stderr.line!(message) ?? {}
			Err(Exit(1))
		}
	}
}

cli = Cli.finish_without_validating(
	{
		version: Opt.str({ short: "", long: "release-version", help: "The version to release.", default: NoDefault }),
		ref_type: Opt.str({ short: "", long: "ref-type", help: "The type of the ref the release was dispatched from.", default: NoDefault }),
		ref_name: Opt.str({ short: "", long: "ref-name", help: "The name of that ref.", default: NoDefault }),
		default_branch: Opt.str({ short: "", long: "default-branch", help: "The repository's default branch.", default: NoDefault }),
	}.Cli,
	CommandLine.config({ name: "check_release_branch.roc", description: "Check that a release may be published from the ref it was dispatched from." }),
)

check_release_branch : Str, Str, Str, Str -> Try({}, [Refused(Str)])
check_release_branch = |version, ref_type, ref_name, default_branch| {
	if ref_type != "branch" {
		return Err(Refused("Releases must be dispatched from a branch"))
	}
	if ref_name != default_branch and !is_release_candidate(version) {
		return Err(Refused("Only X.Y.Z-rcN release candidates may be published from a non-default branch"))
	}
	Ok({})
}

## `X.Y.Z-rcN`, each of X, Y and Z one or more digits and N a number without
## a leading zero.
is_release_candidate : Str -> Bool
is_release_candidate = |version|
	match version.split_first("-rc") {
		Ok({ before, after }) => is_core_version(before) and is_candidate_number(after.to_utf8())
		Err(_) => False
	}

is_core_version : Str -> Bool
is_core_version = |text| {
	parts = text.split_on(".")
	parts.len() == 3 and parts.all(|part| is_digits(part.to_utf8()))
}

is_candidate_number : List(U8) -> Bool
is_candidate_number = |bytes|
	match bytes {
		[first, ..] => first != '0' and is_digits(bytes)
		[] => False
	}

is_digits : List(U8) -> Bool
is_digits = |bytes| !bytes.is_empty() and bytes.all(|byte| byte >= '0' and byte <= '9')

# Tests

# The default branch accepts stable and candidate versions.
expect ["0.26.0", "0.26.0-rc1"].all(|version| check_release_branch(version, "branch", "main", "main").is_ok())

# Another branch accepts numbered candidates.
expect ["0.26.0-rc1", "0.26.0-rc12"].all(|version| check_release_branch(version, "branch", "fix/msvc-runtime-inputs", "main").is_ok())

# Another branch refuses anything else.
expect ["0.26.0", "0.26.0-beta1", "0.26.0-rc0", "0.26.0-rc01", "0.26.0-rc1+build", "0.26.0-rc1\n", "0.26-rc1", "a.b.c-rc1", "0.26.0-rc"].all(|version| check_release_branch(version, "branch", "feature", "main").is_err())

# A tag is refused, even one named like the default branch.
expect ["main", "0.26.0-rc1"].all(|ref| check_release_branch("0.26.0-rc1", "tag", ref, "main").is_err())

expect check_release_branch("0.26.0", "tag", "main", "main") == Err(Refused("Releases must be dispatched from a branch"))
