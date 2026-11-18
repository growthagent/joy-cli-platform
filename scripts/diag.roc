#!/usr/bin/env roc
app [main!] {
	pf: platform "https://github.com/niclas-ahden/basic-cli/releases/download/0.32.0/3MnQnCrtfe6XS5qx58MnAGU6iWk8i1N24MYfoejcWeax.tar.zst",
}

import pf.Stdout
import Files
import Targets

## Why scripts/test.roc finds no targets on one system: each step of
## Targets.declared, on a line written here and on the platform's own file.
main! = |_args| {
	line = "\t\tx64mac: { inputs: [\"libhost.a\", app] },"
	Stdout.line!("a line written here parses to: ${Str.inspect(Targets.declared(line))}")?
	trimmed = line.trim_start()
	Stdout.line!("trim_start: ${Str.inspect(trimmed)}")?
	Stdout.line!("split_first: ${Str.inspect(trimmed.split_first(":"))}")?
	Stdout.line!("all name bytes: ${Str.inspect("x64mac".to_utf8().all(|b| (b >= '0' and b <= '9') or (b >= 'a' and b <= 'z')))}")?
	Stdout.line!("split_on: ${Str.inspect("a\nb".split_on("\n"))}")?
	Stdout.line!("keep_oks: ${Str.inspect(["a: b", "nope"].keep_oks(|l| l.split_first(":")))}")?
	Stdout.line!("starts_with: ${Str.inspect("{ inputs: [] }".starts_with("{"))}")?
	Stdout.line!("split_last: ${Str.inspect("\"libhost.a\", app] },".split_last("]"))}")?
	match Files.read_text!("platform/main.roc") {
		Ok(text) => {
			Stdout.line!("the file: ${text.count_utf8_bytes().to_str()} bytes, ${text.split_on("\n").len().to_str()} lines")?
			Stdout.line!("its lines naming x64mac: ${Str.inspect(text.split_on("\n").keep_if(|l| l.contains("x64mac")))}")?
			Stdout.line!("its targets: ${Str.inspect(Targets.declared(text))}")?
		}

		Err(Failed(message)) => Stdout.line!("could not read the file: ${message}")?
	}
	Ok({})
}
