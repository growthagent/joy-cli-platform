## Exercise automatic native-resource cleanup across aliases, lists, and early returns.
app [main!] { pf: platform "../../platform/main.roc" }

import pf.Env
import pf.File
import pf.OsStr
import pf.Path
import pf.Stdout

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	Env.with_temp_dir!(
		|workspace| {
			path = Path.join(workspace, "lines.txt")
			Path.write_utf8!(path, "first\nsecond\n")?
			for early in [False, True] {
				match read_aliases!(path, early) {
					Ok(_) => {}
					Err(ExpectedEarlyReturn) => {}
					Err(err) => return Err(err)
				}
			}
			Path.delete!(path)
		},
	)?

	Stdout.line!("Resource aliases and early returns cleaned up")
}

read_aliases! = |path, early| {
	reader = File.open_reader!(path)?
	aliases = [reader, reader]
	if early {
		return Err(ExpectedEarlyReturn)
	}
	var $lines = []
	for alias in aliases {
		$lines = List.append($lines, File.Reader.read_until!(alias, '\n')?)
	}
	expect $lines == [Str.to_utf8("first\n"), Str.to_utf8("second\n")]
	Ok({})
}
