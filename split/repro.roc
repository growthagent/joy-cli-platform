app [main!] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst" }

import pf.Stdout

main! = |_args| {
	Stdout.line!(Str.inspect("key: a value that is long enough to show it".split_first(":")))?
	Stdout.line!(Str.inspect("key: a value long enough".split_first(":")))?
	Stdout.line!(Str.inspect("key: short".split_first(":")))?
	Ok({})
}
