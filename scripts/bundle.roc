#!/usr/bin/env roc
app [main!] {
	pf: platform "https://github.com/niclas-ahden/basic-cli/releases/download/0.32.0/3MnQnCrtfe6XS5qx58MnAGU6iWk8i1N24MYfoejcWeax.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.10.2/7CdYzjBAJmprmnK45oTpmH6BXt76ZASN2Ck5uZQEoWsK.tar.zst",
}

import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path
import weaver.Cli
import weaver.Opt
import weaver.Param
import CommandLine
import Files
import PlatformBundle
import Process

## Bundles the platform with `roc bundle`. Run it from the repository root:
##
##     roc scripts/bundle.roc [--output-dir DIR] [--stub-missing-targets] [-- ROC BUNDLE ARGS...]
##
## PlatformBundle.roc says what the bundle holds.
##
## `--stub-missing-targets` creates empty placeholders for target inputs that
## were not built, for local test bundles only, and such a bundle goes without
## Rust's notices when rust-docs is not installed. The arguments after `--` go to
## `roc bundle`. ROC names the roc to run, `roc` by default. A failed
## `roc bundle` ends the script with its exit code.
## `roc test scripts/bundle.roc` runs the tests.
main! : _ => Try({}, _)
main! = |raw_args| {
	args = CommandLine.read!(cli, raw_args)?
	Process.finish!(run!(args))
}

cli = Cli.finish_without_validating(
	{
		output_dir: Opt.maybe_str({ short: "", long: "output-dir", help: "The folder to write the bundle to, the repository root by default." }),
		stub_missing_targets: Opt.flag({ short: "", long: "stub-missing-targets", help: "Create empty placeholders for target inputs that were not built (local test bundles only)." }),
		roc_args: Param.str_list({ name: "roc-bundle-args", help: "Arguments for roc bundle, after --." }),
	}.Cli,
	CommandLine.config({ name: "bundle.roc", description: "Bundle the platform with roc bundle." }),
)

run! : { output_dir : Try(Str, [NoValue]), stub_missing_targets : Bool, roc_args : List(Str) } => Try({}, [Failed(Str), CommandFailed(Str, I32)])
run! = |args| {
	root = Files.root!()?
	options = { output_dir: args.output_dir ?? root, stub_missing_targets: args.stub_missing_targets, roc_args: args.roc_args }
	PlatformBundle.run!(root, options, run_roc!)
}

## Runs ROC, `roc` by default, in a folder on this terminal.
run_roc! : Str, List(Str) => Try({}, [Failed(Str), CommandFailed(Str, I32)])
run_roc! = |dir, args| {
	roc = Env.var_str!(OsStr.from_str("ROC")) ?? "roc"
	output = Cmd.new(OsStr.from_str(roc)).args(args.map(OsStr.from_str)).cwd(Path.utf8(dir)).inherit_stdio().run!() ? |err| Failed("Could not run ${roc}: ${Str.inspect(err)}")
	match output.status {
		Exited(0) => Ok({})
		status => Err(CommandFailed("${roc} bundle", Process.exit_code(status)))
	}
}
