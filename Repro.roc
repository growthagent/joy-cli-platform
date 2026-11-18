Repro := [].{
	## The targets a platform header declares, each with the names of its
	## inputs: the quoted names in `<target>: { inputs: [...] }`.
	declared : Str -> List((Str, List(Str)))
	declared = |source|
		source.split_on("\n").keep_oks(
			|line| {
				{ before: target, after } = line.trim_start().split_first(":") ? |_| NotATarget
				is_name = |byte| (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or byte == '_'
				if target.is_empty() or !target.to_utf8().all(is_name) {
					return Err(NotATarget)
				}
				rest = after.trim_start()
				if !rest.starts_with("{") {
					return Err(NotATarget)
				}
				opened = rest.drop_prefix("{").trim_start()
				if !opened.starts_with("inputs:") {
					return Err(NotATarget)
				}
				list = opened.drop_prefix("inputs:").trim_start()
				if !list.starts_with("[") {
					return Err(NotATarget)
				}
				{ before: inside, .. } = list.drop_prefix("[").split_last("]") ? |_| NotATarget
				# The quoted texts are every other part between quotes.
				names = inside.split_on("\"").map_with_index(|part, index| (part, index)).keep_if(|(part, index)| index % 2 == 1 and !part.is_empty()).map(|(part, _)| part)
				Ok((target, names))
			},
		)
}

expect Repro.declared("\ttargets: {\n\t\tinputs_dir: \"targets/\",\n\t\tx64mac: { inputs: [\"libhost.a\", app] },\n\t\tx64musl: { inputs: [\"rcrt1.o\", \"libhost.a\", app, \"libc.a\"] },\n\t\tx64win: { inputs: [\"host.lib\", app, \"windows_support.lib\"] }\n\t}\n") == [("x64mac", ["libhost.a"]), ("x64musl", ["rcrt1.o", "libhost.a", "libc.a"]), ("x64win", ["host.lib", "windows_support.lib"])]

expect Repro.declared("\tx64mac: { inputs: [\"libhost.a\", app] },\n").len() == 1
expect "x64mac: { inputs: [] }".split_first(":").map_ok(|{ before, .. }| before) == Ok("x64mac")
expect "abc".to_utf8().all(|byte| byte >= 'a' and byte <= 'z')
expect ["a: b", "nope"].keep_oks(|line| line.split_first(":")).len() == 1
expect "  x64mac".trim_start() == "x64mac"
expect "a\nb".split_on("\n").len() == 2
expect "\t\tx64mac: { inputs: [\"libhost.a\", app] },".trim_start().split_first(":").map_ok(|{ before, .. }| before) == Ok("x64mac")
expect "one line of some length here\nand a second line of some length\nand a third".split_on("\n").len() == 3
