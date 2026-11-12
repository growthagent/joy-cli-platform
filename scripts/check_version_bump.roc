#!/usr/bin/env roc
app [main!] {
	pf: platform "https://github.com/niclas-ahden/basic-cli/releases/download/0.31.0/Ff3fkK1TjYTVxMj9V21FP24ojTJXYk314Fbo1whBZ6Yf.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.10.2/7CdYzjBAJmprmnK45oTpmH6BXt76ZASN2Ck5uZQEoWsK.tar.zst",
}

import pf.Cmd
import pf.Duration
import pf.OsStr
import pf.Path
import pf.Stderr
import pf.Stdout
import weaver.Cli
import weaver.Opt
import CommandLine
import Files

## Runs the release API comparison, `roc bump`, with a bounded wait and keeps
## what it printed.
##
##     roc scripts/check_version_bump.roc --release-version VERSION [--previous-url URL]
##         [--entrypoint platform/main.roc] [--output-file .release/bump-output.txt]
##         [--mode warn|require|off] [--dry-run true|false] [--timeout-seconds 120]
##
## `roc bump` compares the platform with the previous release and expects the
## base of VERSION (`0.23.0` for `0.23.0-rc1`). Everything it prints goes to
## the output file, which is printed afterwards, so a hang still leaves its
## diagnostics behind. A failure, a timeout, a missing previous release or a
## compiler that cannot be started is a warning with `--mode warn` and an
## error, exit 1, with `--mode require`. `--mode off` and `--dry-run true`
## skip the check. Exits 2 on a bad command line.
##
## `roc test scripts/check_version_bump.roc` runs the tests at the bottom.
main! : _ => Try({}, _)
main! = |raw_args| {
	args = CommandLine.read!(cli, raw_args)?
	timeout =
		match positive_seconds(args.timeout_seconds ?? "120") {
			Ok(seconds) => seconds
			Err(NotPositive) => return CommandLine.fail!(cli, "--timeout-seconds must be a positive finite number")
		}
	options = {
		version: args.version,
		previous_url: args.previous_url ?? "",
		entrypoint: args.entrypoint ?? "platform/main.roc",
		output_file: args.output_file ?? ".release/bump-output.txt",
		mode: mode_of(args.mode ?? "warn"),
		dry_run: (args.dry_run ?? "false") == "true",
		timeout,
	}
	match check_bump!(options) {
		Ok(0) => Ok({})
		Ok(code) => Err(Exit(code))
		Err(Failed(message)) => {
			Stderr.line!("error: ${message}") ?? {}
			Err(Exit(1))
		}
	}
}

cli = Cli.finish_without_validating(
	{
		version: Opt.str({ short: "", long: "release-version", help: "The version being released.", default: NoDefault }),
		previous_url: Opt.maybe_str({ short: "", long: "previous-url", help: "The URL of the previous release." }),
		entrypoint: Opt.maybe_str({ short: "", long: "entrypoint", help: "The platform's main.roc, platform/main.roc by default." }),
		output_file: Opt.maybe_str({ short: "", long: "output-file", help: "The file for roc bump's output, .release/bump-output.txt by default." }),
		mode: CommandLine.choice({ long: "mode", help: "warn reports a failed check, require fails with it and off skips it. warn by default.", choices: ["warn", "require", "off"] }),
		dry_run: CommandLine.choice({ long: "dry-run", help: "true skips the check. false by default.", choices: ["true", "false"] }),
		timeout_seconds: Opt.maybe_str({ short: "", long: "timeout-seconds", help: "How long roc bump may run, 120 by default." }),
	}.Cli,
	CommandLine.config({ name: "check_version_bump.roc", description: "Run roc bump against the previous release with a bounded wait." }),
)

Mode : [Warn, Require, Off]

mode_of : Str -> Mode
mode_of = |text|
	match text {
		"require" => Require
		"off" => Off
		_ => Warn
	}

Options : { version : Str, previous_url : Str, entrypoint : Str, output_file : Str, mode : Mode, dry_run : Bool, timeout : Dec }

## How a check went before its outcome is reported.
Outcome : [Passed, NoPrevious, Exited(I32), Signaled(I32), TimedOut, CouldNotRun(Str), Interrupted]

## Runs the check and returns the exit code.
check_bump! : Options => Try(I32, [Failed(Str)])
check_bump! = |options| {
	output_file = options.output_file
	match skip_reason(options.mode, options.dry_run) {
		Ok(reason) => {
			Files.write_text!(output_file, "roc bump check skipped because ${reason}.\n")?
			return Ok(0)
		}
		Err(NotSkipped) => {}
	}
	Files.write_text!(output_file, "")?
	outcome =
		if options.previous_url.is_empty() {
			NoPrevious
		} else {
			run_bump!(bump_args(options.previous_url, options.version, options.entrypoint), output_file, options.timeout)
		}
	failure = failure_of(outcome, options.timeout)
	match failure {
		Ok(message) => Path.utf8(output_file).append_utf8!("\n${message}\n") ? |err| Failed("could not write ${output_file}: ${Str.inspect(err)}")
		Err(NoFailure) => {}
	}
	diagnostic = Files.read_text!(output_file)?
	if !diagnostic.is_empty() {
		Stdout.write!(if (diagnostic.ends_with("\n")) diagnostic else "${diagnostic}\n") ?? {}
	}
	match failure {
		Ok(message) => {
			Stderr.line!("${level(options.mode)}: ${message}") ?? {}
			Ok(exit_code(options.mode))
		}
		Err(NoFailure) => Ok(0)
	}
}

## Runs `roc bump` with its output in the output file, standard error
## merged into it, and kills it and what it started at the deadline.
run_bump! : List(Str), Str, Dec => Outcome
run_bump! = |args, output_file, timeout| {
	command = Cmd.new(OsStr.from_str("roc"))
		.args(args.map(OsStr.from_str))
		.stdin(Null)
		.stdout(File(Path.utf8(output_file), Append, {}))
		.stderr(MergeWithStdout)
		.timeout(Duration.nanos(nanos_of(timeout)))
		.manage_tree(True)
	match command.run!() {
		Ok(output) =>
			match output.status {
				Exited(0) => Passed
				Exited(code) => Exited(code)
				Signaled(signal) => Signaled(signal)
			}
		Err(CmdErr(TimedOut(_))) => TimedOut
		Err(CmdErr(err)) => CouldNotRun(err.to_str())
		Err(Interrupted) => Interrupted
	}
}

## Why the check is skipped, if it is.
skip_reason : Mode, Bool -> Try(Str, [NotSkipped])
skip_reason = |mode, dry_run|
	if dry_run {
		Ok("dry-run release")
	} else {
		match mode {
			Off => Ok("bump_check is off")
			_ => Err(NotSkipped)
		}
	}

## The arguments of `roc bump`. It compares the base version, also when a
## prerelease is published.
bump_args : Str, Str, Str -> List(Str)
bump_args = |previous_url, version, entrypoint| ["bump", "--old", previous_url, "--expect", base_version(version), entrypoint]

## A version without its prerelease and build parts.
base_version : Str -> Str
base_version = |version| {
	without_prerelease = match version.split_first("-") {
		Ok({ before, .. }) => before
		Err(_) => version
	}
	match without_prerelease.split_first("+") {
		Ok({ before, .. }) => before
		Err(_) => without_prerelease
	}
}

failure_of : Outcome, Dec -> Try(Str, [NoFailure])
failure_of = |outcome, timeout|
	match outcome {
		Passed => Err(NoFailure)
		NoPrevious => Ok("No previous release bundle found, roc bump check skipped.")
		Exited(code) => Ok("roc bump exited with status ${code.to_str()}.")
		Signaled(signal) => Ok("roc bump exited with status -${signal.to_str()}.")
		TimedOut => Ok("roc bump timed out after ${seconds_text(timeout)} seconds.")
		CouldNotRun(reason) => Ok("Could not run roc bump: ${reason}")
		Interrupted => Ok("roc bump was interrupted.")
	}

level : Mode -> Str
level = |mode|
	match mode {
		Warn => "warning"
		_ => "error"
	}

exit_code : Mode -> I32
exit_code = |mode|
	match mode {
		Warn => 0
		_ => 1
	}

## Seconds as written, without a fraction when they are whole: `120`, `1.5`.
seconds_text : Dec -> Str
seconds_text = |seconds| {
	attos = seconds.to_attos()
	whole : I128
	whole = attos // 1_000_000_000_000_000_000
	if (whole * 1_000_000_000_000_000_000 == attos) whole.to_str() else seconds.to_str()
}

nanos_of : Dec -> U64
nanos_of = |seconds| {
	nanos : I128
	nanos = seconds.to_attos() // 1_000_000_000
	if (nanos < 1) 1 else if (nanos > 18_000_000_000_000_000_000) 18_000_000_000_000_000_000 else nanos.to_u64_wrap()
}

positive_seconds : Str -> Try(Dec, [NotPositive])
positive_seconds = |text|
	match Dec.from_str(text.trim()) {
		Ok(seconds) if seconds > 0 => Ok(seconds)
		_ => Err(NotPositive)
	}

# Tests

# The comparison expects the base version, also for a prerelease.
expect bump_args("https://example.com/0.22.2/pkg.tar.zst", "0.23.0-rc1", "platform/main.roc") == ["bump", "--old", "https://example.com/0.22.2/pkg.tar.zst", "--expect", "0.23.0", "platform/main.roc"]
expect base_version("1.2.3+build.5") == "1.2.3" and base_version("1.2.3-rc1+b") == "1.2.3" and base_version("1.2.3") == "1.2.3"

# A dry run and `--mode off` skip the check, whatever the mode.
expect skip_reason(Require, True) == Ok("dry-run release")
expect skip_reason(Off, False) == Ok("bump_check is off")
expect skip_reason(Warn, False) == Err(NotSkipped) and skip_reason(Require, False) == Err(NotSkipped)

# A passing comparison is no failure.
expect failure_of(Passed, 120) == Err(NoFailure)

# A failure, a timeout, a missing previous release and a missing compiler
# each say what happened.
expect failure_of(Exited(7), 120) == Ok("roc bump exited with status 7.")
expect failure_of(TimedOut, 1) == Ok("roc bump timed out after 1 seconds.")
expect failure_of(TimedOut, 1.5) == Ok("roc bump timed out after 1.5 seconds.")
expect failure_of(NoPrevious, 120) == Ok("No previous release bundle found, roc bump check skipped.")
expect failure_of(CouldNotRun("could not start roc: not found"), 120) == Ok("Could not run roc bump: could not start roc: not found")

# A failure warns and passes with `--mode warn`, and fails with `--mode require`.
expect level(Warn) == "warning" and exit_code(Warn) == 0
expect level(Require) == "error" and exit_code(Require) == 1

expect nanos_of(1.5) == 1_500_000_000 and nanos_of(120) == 120_000_000_000

# A timeout must be a positive number.
expect positive_seconds(" 2.5") == Ok(2.5) and positive_seconds("0") == Err(NotPositive) and positive_seconds("-1") == Err(NotPositive) and positive_seconds("x") == Err(NotPositive)
