## Report the size in bytes of a path supplied on the command line.
app [main!] { pf: platform "https://github.com/growthagent/joy-cli-platform/releases/download/0.1.0-rc1/71QJT9cSt2W6XM4ovm4w6A2PAnq9uUpzn7jxT8PiTGqX.tar.zst" }

import pf.OsStr
import pf.Stdout
import pf.Path

main! : List(OsStr) => Try({}, _)
main! = |args| {
	file : Path
	file = path_argument(args)?

	file_size : U64
	file_size = file.size_in_bytes!()?

	Stdout.line!("${file.display()} is ${file_size.to_str()} bytes")?

	Ok({})
}

path_argument : List(OsStr) -> Try(Path, [MissingPathArgument])
path_argument = |args|
	match args {
		[first, ..] => Ok(Path.from_os_str(first))
		[] => Err(MissingPathArgument)
	}
