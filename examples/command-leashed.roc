## Long-lived child processes that cannot outlive this program, with
## [Cmd.spawn_leashed!]. A leashed child, and its whole process tree, is taken
## down when this program ends, including on the deaths that skip cleanup such
## as Ctrl+C, a crash, or `kill -9`. Use it for a server or driver you
## supervise, so a cancelled run never leaves a stray behind.
app [main!] { pf: platform "../platform/main.roc" }

import pf.Cmd
import pf.Duration
import pf.OsStr
import pf.Stdout

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	# --- talk to a leashed child over pipes ---
	# Standard streams are inherited, exactly as with spawn!, so ask for pipes.
	cat = Cmd.new("cat").stdin(Pipe).stdout(Pipe).spawn_leashed!()?
	cat.write_utf8!("hello, leash!\n", Duration.seconds(1))?
	cat.close_stdin!()?
	echoed = read_all!(cat, [])?
	Stdout.line!("cat echoed: ${Str.from_utf8_lossy(echoed).trim()}")?
	_ = cat.wait!()?

	# --- a leashed child reports its own exit status ---
	coder = Cmd.new("sh").args(["-c", "exit 7"]).spawn_leashed!()?
	done = coder.wait!()?
	Stdout.line!("leashed exit: ${Str.inspect(done.status)}")?

	# --- close! takes a running leashed tree down at once ---
	# The child backgrounds a grandchild, so this proves the whole group goes,
	# not just the direct child. `up` on stdout is the readiness signal.
	server = Cmd.new("sh").args(["-c", "sleep 100 & echo up; wait"]).stdout(Pipe).spawn_leashed!()?
	_marker = read_line!(server, [])?
	server.close!()?
	Stdout.line!("leashed tree closed")?

	Ok({})
}

## Drain a child's piped stdout to its end, concatenating the chunks.
read_all! : Cmd.Child, List(U8) => Try(List(U8), _)
read_all! = |child, acc|
	match child.read!(Duration.seconds(1)) {
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
		match child.read!(Duration.seconds(1)) {
			Ok(Stdout(chunk)) => read_line!(child, acc.concat(chunk))
			Ok(Stderr(_)) => read_line!(child, acc)
			Err(EndOfInput) => Ok(acc)
			Err(other) => Err(other)
		}
	}
