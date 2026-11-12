import pf.System

## The targets this platform builds a host for, shared by the scripts.
Targets := [].{

	## Every Unix target, by Roc target name, with the Rust target its host is
	## built for. The macOS and Linux hosts are built on any of them.
	unix : List((Str, Str))
	unix = [
		("x64mac", "x86_64-apple-darwin"),
		("arm64mac", "aarch64-apple-darwin"),
		("x64musl", "x86_64-unknown-linux-musl"),
		("arm64musl", "aarch64-unknown-linux-musl"),
	]

	## The Windows host's Rust target. It is built on Windows only.
	windows_rust_target : Str
	windows_rust_target = "x86_64-pc-windows-msvc"

	## Every target, Windows last.
	all : List((Str, Str))
	all = Targets.unix.append(("x64win", Targets.windows_rust_target))

	## Every Roc target name, Windows last.
	roc_names : List(Str)
	roc_names = Targets.all.map(|(roc_target, _)| roc_target)

	## The Rust target of a Roc target.
	rust_target_of : Str -> Try(Str, [UnknownTarget(Str)])
	rust_target_of = |roc_target|
		Targets.all.find_first(|(name, _)| name == roc_target).map_ok(|(_, rust_target)| rust_target).map_err(|_| UnknownTarget(roc_target))

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

	## The Roc target of the machine this runs on, when the platform builds
	## for it.
	native! : () => Try(Str, [Failed(Str)])
	native! = || {
		target = System.target!()
		match (target.os(), target.arch()) {
			(Windows(_), X64) => Ok("x64win")
			(MacOS(_), Arm64) => Ok("arm64mac")
			(MacOS(_), X64) => Ok("x64mac")
			(Linux(_), Arm64) => Ok("arm64musl")
			(Linux(_), X64) => Ok("x64musl")
			(Windows(_), Arm64) => Err(Failed("The platform has no host for Windows on Arm64"))
		}
	}
}

expect Targets.roc_names == ["x64mac", "arm64mac", "x64musl", "arm64musl", "x64win"]
expect Targets.rust_target_of("x64win") == Ok("x86_64-pc-windows-msvc")
expect Targets.rust_target_of("riscv") == Err(UnknownTarget("riscv"))

expect Targets.declared("\ttargets: {\n\t\tinputs_dir: \"targets/\",\n\t\tx64mac: { inputs: [\"libhost.a\", app] },\n\t\tx64musl: { inputs: [\"rcrt1.o\", \"libhost.a\", app, \"libc.a\"] },\n\t\tx64win: { inputs: [\"host.lib\", app, \"windows_support.lib\"] }\n\t}\n") == [("x64mac", ["libhost.a"]), ("x64musl", ["rcrt1.o", "libhost.a", "libc.a"]), ("x64win", ["host.lib", "windows_support.lib"])]
