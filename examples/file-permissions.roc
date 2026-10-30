## Inspect whether a file is executable, readable, and writable.
app [main!] { pf: platform "https://github.com/growthagent/joy-cli-platform/releases/download/0.1.0-rc1/71QJT9cSt2W6XM4ovm4w6A2PAnq9uUpzn7jxT8PiTGqX.tar.zst" }

import pf.OsStr
import pf.Stdout
import pf.Path

main! : List(OsStr) => Try({}, _)
main! = |args| {
	file : Path
	file = path_argument(args)?

	is_executable = file.is_executable!()?
	is_readable = file.is_readable!()?
	is_writable = file.is_writable!()?

	Stdout.line!(
		\\${file.display()} file permissions:
		\\    Executable: ${Str.inspect(is_executable)}
		\\    Readable: ${Str.inspect(is_readable)}
		\\    Writable: ${Str.inspect(is_writable)}
	)?

	Ok({})
}

## Parse the first argument into a Path
path_argument : List(OsStr) -> Try(Path, _)
path_argument = |args|
	match args {
		[first, ..] => Ok(Path.from_os_str(first))
		[] => Err(MissingPathArgument)
	}
