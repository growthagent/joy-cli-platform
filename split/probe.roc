app [main!] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst" }

import pf.Stdout

## Builds `len` bytes of "a" with ":" at `pos`. `one` is 1 at runtime, so
## nothing here can be folded at compile time.
text = |len, pos, one| Str.concat(Str.concat(Str.repeat("a", pos * one), ":"), Str.repeat("b", (len - pos - 1) * one))

before_len = |result|
	match result {
		Ok({ before, .. }) => before.count_utf8_bytes().to_str()
		Err(NotFound) => "none"
	}

main! = |args| {
	one = if args.len() < 1000 1 else 2
	Stdout.line!("split_first(\":\"): length, then position:found for each position tried")?
	for len in [4, 8, 15, 16, 17, 18, 23, 24, 25, 31, 32, 33, 34, 40, 48, 49, 63, 64, 65, 66, 67, 80, 96, 97, 98, 100, 128, 129, 130, 200] {
		var $row = "${len.to_str()}:"
		for pos in [0, 1, 2, 6, 15, 16, 17, 31, 32, 33, 47, 63, 64, 65, 66, 95, 96, 97, 127, 128, 129, 150, 197, 198, 199] {
			if pos < len {
				found = before_len(text(len, pos, one).split_first(":"))
				mark = if found == pos.to_str() "" else " WRONG"
				$row = "${$row} ${pos.to_str()}:${found}${mark}"
			}
		}
		Stdout.line!($row)?
	}

	long = text(40, 6, one)
	short = text(8, 6, one)
	Stdout.line!("40 bytes, \":\" at 6: ${Str.inspect(long)}")?
	Stdout.line!("split_first(\":\")     ${Str.inspect(long.split_first(":"))}")?
	Stdout.line!("split_first(\":b\")    ${Str.inspect(long.split_first(":b"))}")?
	Stdout.line!("split_first(\":bbbbbbbb\") ${Str.inspect(long.split_first(":bbbbbbbb"))}")?
	Stdout.line!("split_last(\":\")      ${Str.inspect(long.split_last(":"))}")?
	Stdout.line!("split_on(\":\")        ${Str.inspect(long.split_on(":"))}")?
	Stdout.line!("split_on(\":b\")       ${Str.inspect(long.split_on(":b"))}")?
	Stdout.line!("replace_each(\":\", \"_\") ${Str.inspect(long.replace_each(":", "_"))}")?
	Stdout.line!("replace_first(\":\", \"_\") ${Str.inspect(long.replace_first(":", "_"))}")?
	Stdout.line!("contains(\":\")        ${Str.inspect(long.contains(":"))}")?
	Stdout.line!("drop_prefix(\"aaaaaa:\") ${Str.inspect(long.drop_prefix("aaaaaa:"))}")?
	Stdout.line!("starts_with(\"aaaaaa:\") ${Str.inspect(long.starts_with("aaaaaa:"))}")?
	Stdout.line!("8 bytes, split_first(\":\") ${Str.inspect(short.split_first(":"))}")?

	lines = Str.join_with(List.repeat("\tline", 20 * one), "\n")
	Stdout.line!("20 lines of \"\\tline\": split_on(\"\\n\") gives ${lines.split_on("\n").len().to_str()}, first two ${Str.inspect(lines.split_on("\n").take_first(2))}")?

	upper = Str.repeat("abcdefghij", 5 * one).with_ascii_uppercased()
	Stdout.line!("with_ascii_uppercased: ${upper}")?
	utf8 = Str.from_utf8(Str.repeat("åäö-abc-", 8 * one).to_utf8())
	Stdout.line!("from_utf8 of 80 bytes: ${Str.inspect(utf8)}")?
	Stdout.line!("trim of 40 bytes: ${Str.inspect(Str.concat("   ", long).trim())}")?
	Ok({})
}
