## Print a minimal greeting to standard output.
app [main!] { pf: platform "https://github.com/growthagent/joy-cli-platform/releases/download/0.1.0-rc4/EQHYpAo8oDkf35M2DAA2nWx6Guyj5aqRf24yLk5JsSVt.tar.zst" }

import pf.OsStr
import pf.Stdout

main! = |_args| {
	Stdout.line!("Hello, World!")?
	Ok({})
}
