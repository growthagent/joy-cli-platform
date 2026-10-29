## Greet a name supplied as a native command-line argument.
app [main!] { pf: platform "https://github.com/growthagent/joy-cli-platform/releases/download/0.1.0-rc1/71QJT9cSt2W6XM4ovm4w6A2PAnq9uUpzn7jxT8PiTGqX.tar.zst" }

import pf.OsStr
import pf.Stdout

main! : List(OsStr) => Try({}, _)
main! = |args| {
	name : Str
	name = greeting_name(args)

	Stdout.line!("Hello, ${name}, from joy-cli-platform!")?

	Ok({})
}

greeting_name : List(OsStr) -> Str
greeting_name = |args|
	match args {
		[first, ..] => OsStr.display(first)
		[] => "friend"
	}
