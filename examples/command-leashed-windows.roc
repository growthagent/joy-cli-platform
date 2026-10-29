## Long-lived child processes that cannot outlive this program, with
## [Cmd.spawn_leashed!], driven with Windows commands. On Windows the leash is
## a Job Object that dies with this program, so the whole tree goes on any
## exit, including a crash or an outside TerminateProcess.
## examples/command-leashed.roc covers the same ground with Unix commands.
## This one runs only on Windows.
app [main!] { pf: platform "../platform/main.roc" }

import pf.Cmd
import pf.Duration
import pf.OsStr
import pf.Stdout

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	# --- a leashed child reports its own exit status and output ---
	# Standard streams are inherited, exactly as with spawn!, so ask for capture.
	greeter = Cmd.new("cmd").args(["/c", "echo hello"]).stdout(Capture).spawn_leashed!()?
	greeted = greeter.wait!()?
	Stdout.line!("echo exit: ${Str.inspect(greeted.status)}")?
	Stdout.line!("echo said: ${Str.from_utf8_lossy(greeted.stdout_bytes).trim()}")?

	# --- talk to a leashed child over pipes ---
	sorter = Cmd.new("sort").stdin(Pipe).stdout(Pipe).spawn_leashed!()?
	sorter.write_utf8!("banana\r\napple\r\ncherry\r\n", Duration.seconds(1))?
	sorter.close_stdin!()?
	sorted = read_all!(sorter, [])?
	Stdout.line!("sort said: ${Str.from_utf8_lossy(sorted).trim()}")?
	_ = sorter.wait!()?

	# --- close! takes a running leashed tree down at once ---
	# The child starts a grandchild, so this proves the whole job goes, not
	# just the direct child. `up` on stdout is the readiness signal.
	server =
		Cmd.new("powershell")
			.args([
				"-NoProfile",
				"-Command",
				"Start-Process ping -ArgumentList '-n','600','127.0.0.1' -WindowStyle Hidden; Write-Output up; Start-Sleep -Seconds 600",
			])
			.stdout(Pipe)
			.spawn_leashed!()?
	_marker = read_line!(server, [])?
	server.close!()?
	Stdout.line!("leashed tree closed")?

	Ok({})
}

## Drain a child's piped stdout to its end, concatenating the chunks.
read_all! : Cmd.Child, List(U8) => Try(List(U8), _)
read_all! = |child, acc|
	match child.read!(Duration.seconds(5)) {
		Ok(Stdout(chunk)) => read_all!(child, acc.concat(chunk))
		Ok(Stderr(_)) => read_all!(child, acc)
		Err(EndOfInput) => Ok(acc)
		Err(other) => Err(other)
	}

## Read a child's piped stdout only up to and including the first newline:
## enough to catch a one-line readiness marker without waiting for the child
## to exit.
read_line! : Cmd.Child, List(U8) => Try(List(U8), _)
read_line! = |child, acc|
	if acc.contains(10) {
		Ok(acc)
	} else {
		match child.read!(Duration.seconds(10)) {
			Ok(Stdout(chunk)) => read_line!(child, acc.concat(chunk))
			Ok(Stderr(_)) => read_line!(child, acc)
			Err(EndOfInput) => Ok(acc)
			Err(other) => Err(other)
		}
	}
