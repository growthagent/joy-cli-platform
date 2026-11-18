#!/usr/bin/env roc
app [main!] {
	pf: platform "https://github.com/niclas-ahden/basic-cli/releases/download/0.32.0/3MnQnCrtfe6XS5qx58MnAGU6iWk8i1N24MYfoejcWeax.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.10.2/7CdYzjBAJmprmnK45oTpmH6BXt76ZASN2Ck5uZQEoWsK.tar.zst",
}

import pf.Cmd
import pf.Duration
import pf.Env
import pf.Monotonic
import pf.Path
import pf.Random
import pf.Sleep
import pf.Stdout
import weaver.Cli
import weaver.Param
import CommandLine
import Process

## Exercises the default `systemctl stop` SIGTERM against the built Roc
## fixture (tests/signal-cleanup.roc):
##
##     roc scripts/test_systemd_cleanup.roc BINARY
##
## Run it on a Linux system with systemd as its service manager. It starts
## the fixture as a transient system service, so `systemd-run` and
## `systemctl` run as root: through `sudo` unless the script already runs as
## root. The file models an external resource. Stopping must leave it
## cleaned, not acquired.
main! : _ => Try({}, _)
main! = |raw_args| {
	binary = CommandLine.read!(cli, raw_args)?
	Process.finish!(run!(binary))
}

cli = Cli.finish_without_validating(Param.str({ name: "binary", help: "The signal-cleanup fixture.", default: NoDefault }), CommandLine.config({ name: "test_systemd_cleanup.roc", description: "Stop the signal-cleanup fixture as a systemd service and check its cleanup." }))

run! : Str => Try({}, [Failed(Str)])
run! = |given| {
	binary = Path.display(Path.utf8(given).canonicalize!() ? |_| Failed("No such binary: ${given}"))
	_ = Process.capture!(["chmod", "a+x", binary])?
	as_root = root_prefix!()?
	unit = "basic-cli-cleanup-${unique_hex!()?}.service"
	directory = Env.create_temp_dir_with_prefix!("basic-cli-systemd-") ? |err| Failed("could not create a folder: ${Str.inspect(err)}")
	result = stop_service!(as_root, unit, Path.display(directory), binary)
	for action in ["stop", "reset-failed"] {
		_ = Process.command(as_root.concat(["systemctl", action, unit]))?.run!()
	}
	directory.delete_all!() ?? {}
	result
}

## Starts the fixture as a service, waits for it to acquire its resource,
## stops it with systemctl and checks that it cleaned up.
stop_service! : List(Str), Str, Str, Str => Try({}, [Failed(Str)])
stop_service! = |as_root, unit, directory, binary| {
	marker = "${directory}/resource-state.txt"
	# Keep KillSignal and KillMode at systemd defaults. This is the actual
	# service stop path rather than a direct kill(pid, SIGTERM).
	words = as_root.concat(["systemd-run", "--wait", "--unit", unit, "--property", "Type=exec", "--property", "TimeoutStopSec=10s", "--working-directory", directory, binary, "service"])
	runner = Process.command(words)?
		.stdout(Capture)
		.stderr(MergeWithStdout)
		.spawn!()
		? |err| Failed("could not start systemd-run: ${Str.inspect(err)}")
	result = stop_and_check!(as_root, unit, marker, runner)
	runner.close!() ?? {}
	result
}

stop_and_check! : List(Str), Str, Str, Cmd.Child => Try({}, [Failed(Str)])
stop_and_check! = |as_root, unit, marker, runner| {
	wait_for_marker!(marker, runner, Monotonic.now!())?
	_ = Process.capture!(as_root.concat(["systemctl", "stop", unit]))?
	if read_marker!(marker) != "cleaned" {
		return Err(Failed("Stop skipped application cleanup"))
	}
	# --wait keeps the result even if the inactive transient unit is unloaded
	# before a later `systemctl show` could inspect it.
	output = wait_for_runner!(runner, Monotonic.now!())?
	match output.status {
		Exited(0) => {
			Stdout.line!("Default systemctl stop completed Roc application cleanup") ?? {}
			Ok({})
		}
		_ => Err(Failed(output.stdout_utf8_lossy()))
	}
}

wait_for_marker! : Str, Cmd.Child, Monotonic => Try({}, [Failed(Str)])
wait_for_marker! = |marker, runner, started| {
	if read_marker!(marker) == "acquired" {
		return Ok({})
	}
	finished =
		match runner.poll!() {
			Ok(Running) => False
			_ => True
		}
	if finished or started.elapsed!() >= Duration.seconds(10) {
		return Err(Failed("Service did not acquire its resource"))
	}
	Sleep.millis!(20) ? |Interrupted| Failed("Interrupted")
	wait_for_marker!(marker, runner, started)
}

wait_for_runner! : Cmd.Child, Monotonic => Try(Cmd.Output, [Failed(Str)])
wait_for_runner! = |runner, started|
	match runner.poll!() {
		Ok(Finished(output)) => Ok(output)
		Ok(Running) if started.elapsed!() < Duration.seconds(10) => {
			Sleep.millis!(20) ? |Interrupted| Failed("Interrupted")
			wait_for_runner!(runner, started)
		}
		Ok(Running) => Err(Failed("systemd-run did not finish within 10s"))
		Err(err) => Err(Failed("systemd-run failed: ${Str.inspect(err)}"))
	}

read_marker! : Str => Str
read_marker! = |marker| Path.utf8(marker).read_utf8!() ?? ""

## `sudo` unless this already runs as root.
root_prefix! : () => Try(List(Str), [Failed(Str)])
root_prefix! = || {
	uid = Process.capture!(["id", "-u"])?
	Ok(if (uid.trim() == "0") [] else ["sudo"])
}

unique_hex! : () => Try(Str, [Failed(Str)])
unique_hex! = || {
	high = Random.seed_u64!() ? |err| Failed("no random numbers: ${Str.inspect(err)}")
	low = Random.seed_u64!() ? |err| Failed("no random numbers: ${Str.inspect(err)}")
	Ok("${hex(high)}${hex(low)}")
}

## A number as 16 hex digits.
hex : U64 -> Str
hex = |value| {
	digits = [60, 56, 52, 48, 44, 40, 36, 32, 28, 24, 20, 16, 12, 8, 4, 0].map(
		|shift| {
			nibble = value.shr_wrap(shift).bitwise_and(15).to_u8_wrap()
			if (nibble < 10) '0' + nibble else 'a' + nibble - 10
		},
	)
	Str.from_utf8_lossy(digits)
}

expect hex(0x1234_5678_9ABC_DEF0) == "123456789abcdef0" and hex(0) == "0000000000000000"
