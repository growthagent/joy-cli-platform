#!/usr/bin/env roc
app [main!] {
	pf: platform "https://github.com/niclas-ahden/basic-cli/releases/download/0.31.0/Ff3fkK1TjYTVxMj9V21FP24ojTJXYk314Fbo1whBZ6Yf.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.10.2/7CdYzjBAJmprmnK45oTpmH6BXt76ZASN2Ck5uZQEoWsK.tar.zst",
}

import pf.Stdout
import weaver.Cli
import weaver.Opt
import CommandLine
import Files
import HostBuild
import Process
import Targets

## Builds the platform host into platform/targets. Run it from the
## repository root:
##
##     roc scripts/build.roc                  # the host for this machine
##     roc scripts/build.roc --target x64musl # one Roc target
##     roc scripts/build.roc --all            # every macOS and Linux target
##
## x64win is built on Windows only, and `--all` on macOS or Linux only. A
## failed command ends the script with the command's exit code.
## `roc test scripts/build.roc` runs the tests.
main! : _ => Try({}, _)
main! = |raw_args| {
	args = CommandLine.read!(cli, raw_args)?
	if args.all and args.target.is_ok() {
		return CommandLine.fail!(cli, "--all and --target are mutually exclusive")
	}
	if args.target == Ok("x64win") and !Process.is_windows!() {
		return CommandLine.fail!(cli, "x64win host inputs must be built on Windows")
	}
	if args.all and Process.is_windows!() {
		return CommandLine.fail!(cli, "--all requires a macOS or Linux host")
	}
	Process.finish!(run!(args.all, args.target))
}

cli = Cli.finish_without_validating(
	{
		all: Opt.flag({ short: "", long: "all", help: "Build every macOS and Linux target." }),
		target: CommandLine.choice({ long: "target", help: "Build one Roc platform target: ${Str.join_with(Targets.roc_names, ", ")}.", choices: Targets.roc_names }),
	}.Cli,
	CommandLine.config({ name: "build.roc", description: "Build the platform host into platform/targets, for this machine unless --all or --target says otherwise." }),
)

run! : Bool, Try(Str, [NoValue]) => Try({}, [Failed(Str), CommandFailed(Str, I32)])
run! = |all, chosen| {
	_ = Files.root!()?
	match (all, chosen) {
		(_, Ok("x64win")) => HostBuild.build_windows!()?
		(_, Ok(target)) => {
			rust_target = Targets.rust_target_of(target) ? |_| Failed("Unknown target ${target}")
			HostBuild.install_rust_target!(rust_target, True)?
			native = Targets.native!().map_ok(|n| n == target) ?? False
			HostBuild.build_unix_target!(target, native)?
		}
		(True, Err(NoValue)) => {
			Stdout.line!("Building for all targets...\n") ?? {}
			for (_, rust_target) in Targets.unix {
				HostBuild.install_rust_target!(rust_target, False)?
			}
			Stdout.line!("") ?? {}
			for (target, _) in Targets.unix {
				HostBuild.build_unix_target!(target, False)?
				Stdout.line!("") ?? {}
			}
			Stdout.line!("All targets built successfully!") ?? {}
			return Ok({})
		}
		(False, Err(NoValue)) => {
			target = Targets.native!()?
			Stdout.line!("Building for native target: ${target}\n") ?? {}
			if target == "x64win" {
				HostBuild.build_windows!()?
			} else {
				if target == "x64musl" or target == "arm64musl" {
					rust_target = Targets.rust_target_of(target) ? |_| Failed("Unknown target ${target}")
					HostBuild.install_rust_target!(rust_target, False)?
				}
				HostBuild.build_unix_target!(target, True)?
			}
		}
	}
	Stdout.line!("\nBuild complete!") ?? {}
	Ok({})
}
