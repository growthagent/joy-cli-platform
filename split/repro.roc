app [main!] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst" }

import pf.Stdin
import pf.Stdout

main! = |_args| {
	line = Stdin.line!()?
	Stdout.line!(Str.inspect(line.split_first(":")))?
	Ok({})
}
