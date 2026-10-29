## Check the terminal primitives prompts are built on: whether the standard
## streams are terminals, the terminal's size, and reading stdin with a
## timeout, both from pipes and from a terminal in raw mode.
app [main!] { pf: platform "../platform/main.roc" }

import pf.Duration
import pf.OsStr
import pf.Stdin
import pf.Stdout
import pf.Tty

main! : List(OsStr) => Try({}, _)
main! = |args|
	match args.map(OsStr.display) {
		["piped", ..] => piped!()
		["terminal", ..] => terminal!()
		other => Err(UnknownMode(other))
	}

## The runner pipes "abc" to stdin and reads stdout from a pipe.
piped! : () => Try({}, _)
piped! = || {
	stdin_terminal = Tty.is_terminal!(Stdin)
	stdout_terminal = Tty.is_terminal!(Stdout)
	tty = Tty.is_tty!()
	Stdout.line!("piped: stdin ${Str.inspect(stdin_terminal)}, stdout ${Str.inspect(stdout_terminal)}, tty ${Str.inspect(tty)}")?
	size_failed =
		match Tty.size!() {
			Ok(_) => False
			Err(TtyErr(_)) => True
		}
	Stdout.line!("no size without a terminal: ${Str.inspect(size_failed)}")?
	first = Stdin.bytes_within!(Duration.seconds(5))?
	Stdout.line!("read within the timeout: ${Str.from_utf8(first) ?? "?"}")?
	match Stdin.bytes_within!(Duration.millis(50)) {
		Err(EndOfInput) => Stdout.line!("then the end of input")
		other => Err(ExpectedEndOfInput(Str.inspect(other)))
	}
}

## The runner gives the program a terminal of 80 by 24 and types a key once
## raw mode is on.
terminal! : () => Try({}, _)
terminal! = || {
	tty = Tty.is_tty!()
	size = Tty.size!()?
	Stdout.line!("terminal: tty ${Str.inspect(tty)}, ${U16.to_str(size.width)} by ${U16.to_str(size.height)}")?
	# Nothing is typed before raw mode, so this waits out its timeout.
	nothing = Stdin.bytes_within!(Duration.millis(50))?
	Stdout.line!("nothing typed yet: ${Str.inspect(nothing == [])}")?
	Tty.enable_raw_mode!()?
	key = wait_for_key!(100)?
	Tty.disable_raw_mode!()?
	Stdout.line!("key: ${Str.from_utf8(key) ?? "?"}")
}

wait_for_key! : U64 => Try(List(U8), _)
wait_for_key! = |tries_left| {
	bytes = Stdin.bytes_within!(Duration.millis(100))?
	if bytes != [] or tries_left == 0 {
		Ok(bytes)
	} else {
		wait_for_key!(tries_left - 1)
	}
}
