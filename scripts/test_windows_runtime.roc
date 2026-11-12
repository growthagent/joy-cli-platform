#!/usr/bin/env roc
app [main!] {
	pf: platform "https://github.com/niclas-ahden/basic-cli/releases/download/0.31.0/Ff3fkK1TjYTVxMj9V21FP24ojTJXYk314Fbo1whBZ6Yf.tar.zst",
}

import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path
import pf.Stdout
import AppPlatformUrls
import Cargo
import Files
import HostBuild
import PlatformBundle
import Process
import WindowsRuntime

## The Windows build chain's checks that run anywhere, in temporary folders.
## Run it from the repository root, inside `nix develop` or with cargo, rustc
## with rust-docs, Zig and roc on PATH:
##
##     roc scripts/test_windows_runtime.roc
##
## - The bundle carries the Windows notices and PROVENANCE.json to
##   `roc bundle`, puts back a platform/LICENSE that was there, and refuses an
##   unrecorded object file before roc starts.
## - A license file linked to one outside its folder is refused.
## - ZIG selects Zig, also with an empty PATH, and a Zig of another version is
##   refused.
## - cc-rs rebuilds the C code when the Zig compiler or the compiler adapter
##   changes, as HostBuild names the adapter after both, and a cached adapter
##   that changed after it was built is refused.
##
## The last three need Unix and are skipped on Windows, where
## `windows_runtime.roc --test-windows` builds and checks the real host.
##
## `roc test scripts/test_windows_runtime.roc` runs the unit tests of the
## modules it imports.
main! : _ => Try({}, _)
main! = |_args| {
	Process.finish!(run!())?
	Stdout.line!("All Windows build chain checks passed") ?? {}
	Ok({})
}

run! : () => Try({}, [Failed(Str), CommandFailed(Str, I32)])
run! = || {
	root = Files.root!()?
	scratch = Path.display(Env.create_temp_dir_with_prefix!("windows-runtime-test-") ? |err| Failed("Could not create a temporary folder: ${Str.inspect(err)}"))
	result = checks!(root, Files.canonical!(scratch)?)
	_ = Path.utf8(scratch).delete_all!()
	result
}

checks! : Str, Str => Try({}, [Failed(Str), CommandFailed(Str, I32)])
checks! = |root, scratch| {
	WindowsRuntime.check!("the bundle carries the Windows notices", || bundle_test!("${scratch}/bundle"))?
	if Process.is_windows!() {
		Stdout.line!("skip: the linked license, Zig selection and the compiler cache need Unix") ?? {}
		return Ok({})
	}
	WindowsRuntime.check!("a license file linked outside the folder is refused", || linked_license_test!("${scratch}/linked"))?
	WindowsRuntime.check!("ZIG selects a Zig of the pinned version", || zig_test!("${scratch}/zig"))?
	WindowsRuntime.check!("cc-rs rebuilds when the compiler or the adapter changes", || compiler_cache_test!(root, "${scratch}/cache"))
}

expect_that : Bool, Str -> Try({}, [Failed(Str), CommandFailed(Str, I32)])
expect_that = |holds, message| if (holds) Ok({}) else Err(Failed(message))

# The bundle

bundle_test! : Str => Try({}, [Failed(Str), CommandFailed(Str, I32)])
bundle_test! = |root| {
	platform_dir = "${root}/platform"
	windows = "${platform_dir}/targets/x64win"
	for name in WindowsRuntime.libraries.append("host.lib") {
		Files.write_text!("${windows}/${name}", name)?
	}
	license = WindowsRuntime.notice!(windows, "license.txt", "original license".to_utf8())?
	write_fixture_manifest!(windows, license)?
	Files.write_text!("${platform_dir}/main.roc", "\t\tx64win: { inputs: [\"host.lib\", app, \"windows_support.lib\"] },\n")?
	Files.write_text!("${root}/LICENSE", "root license")?
	Files.write_text!("${root}/THIRD_PARTY_LICENSES.md", "root notices")?
	Files.write_text!("${platform_dir}/LICENSE", "existing local license")?
	options = { output_dir: "dist", stub_missing_targets: False, roc_args: [] }
	recorded = "${root}/roc-arguments.txt"
	record! = |dir, args| {
		expect_that(dir == platform_dir, "roc bundle ran in ${dir}, not in ${platform_dir}")?
		Files.write_text!(recorded, Str.join_with(args, "\n"))
	}

	PlatformBundle.run!(root, options, record!)?
	args = Files.read_text!(recorded)?.split_on("\n")
	for wanted in ["targets/x64win/licenses/license.txt", "targets/x64win/PROVENANCE.json", "LICENSE", "THIRD_PARTY_LICENSES.md", "COPYRIGHT-rust-library.html"] {
		expect_that(args.contains(wanted), "roc bundle was not given ${wanted}: ${Str.inspect(args)}")?
	}
	expect_that(Files.read_text!("${platform_dir}/LICENSE")? == "existing local license", "platform/LICENSE was not put back")?
	expect_that(!Files.is_file!("${platform_dir}/THIRD_PARTY_LICENSES.md"), "platform/THIRD_PARTY_LICENSES.md was left behind")?

	# An object file nobody recorded stops the bundle before roc starts.
	_ = Path.utf8(recorded).delete!()
	Files.write_text!("${windows}/licenses/unrecorded.OBJ", "unrecorded")?
	match PlatformBundle.run!(root, options, record!) {
		Err(Failed(message)) if message.contains("inventory mismatch") => {}
		other => return Err(Failed("An unrecorded .OBJ was not refused: ${Str.inspect(other)}"))
	}
	expect_that(!Files.is_file!(recorded), "roc bundle ran despite an unrecorded .OBJ")
}

## Records every library of an input folder as one fixture component with
## one license file.
write_fixture_manifest! : Str, Str => Try({}, [Failed(Str), CommandFailed(Str, I32)])
write_fixture_manifest! = |inputs, license| {
	component = Object([
		("license", Text("MIT")),
		("license_files", Array([Text(license)])),
		("redistribution_basis", Text("fixture")),
		("sources", Array([Object([("sha256", Text("fixture"))])])),
		("build_commands", Array([Array([Text("fixture")])])),
	])
	WindowsRuntime.write_manifest!(inputs, [("fixture", component)], WindowsRuntime.libraries.append("host.lib").map(|name| (name, "fixture")))
}

## A license file linked to one outside the input folder is refused, as its
## text would not travel with the folder.
linked_license_test! : Str => Try({}, [Failed(Str), CommandFailed(Str, I32)])
linked_license_test! = |dir| {
	inputs = "${dir}/x64win"
	for name in WindowsRuntime.libraries.append("host.lib") {
		Files.write_text!("${inputs}/${name}", name)?
	}
	Files.write_text!("${dir}/outside.txt", "license outside")?
	Files.write_text!("${inputs}/licenses/inside.txt", "license inside")?
	Process.run!(["ln", "-s", "../../outside.txt", "${inputs}/licenses/license.txt"], [])?
	write_fixture_manifest!(inputs, "licenses/inside.txt")?
	expect_that(WindowsRuntime.validate!(inputs, True).is_ok(), "A license file inside the folder was refused")?
	write_fixture_manifest!(inputs, "licenses/license.txt")?
	match WindowsRuntime.validate!(inputs, True) {
		Err(Failed(message)) if message.contains("invalid Windows license file: licenses/license.txt") => Ok({})
		other => Err(Failed("A license file linked outside the folder was not refused: ${Str.inspect(other)}"))
	}
}

# Zig

## A program that answers `version` and `env` as Zig does.
fake_zig! : Str, Str => Try(Str, [Failed(Str), CommandFailed(Str, I32)])
fake_zig! = |dir, version| {
	path = "${dir}/zig"
	Files.write_text!(path, "#!/bin/sh\ncase \"$1\" in\n  version) echo ${version} ;;\n  env) echo '.{ .lib_dir = \"${dir}/lib\" }' ;;\nesac\n")?
	Process.run!(["chmod", "+x", path], [])?
	Ok(path)
}

zig_test! : Str => Try({}, [Failed(Str), CommandFailed(Str, I32)])
zig_test! = |dir| {
	zig = fake_zig!("${dir}/pinned", WindowsRuntime.zig_release.version)?
	# Only ZIG names the compiler. No zig can be found on PATH.
	expect_that(WindowsRuntime.resolve_zig_in!(zig, "") == Ok(zig), "ZIG with an empty PATH did not select ${zig}")?
	expect_that(WindowsRuntime.zig_lib_dir!(zig)? == "${dir}/pinned/lib", "zig env's lib_dir was not read")?
	expect_that(WindowsRuntime.resolve_zig_in!("zig", "${dir}/pinned") == Ok(zig), "zig was not found on PATH")?
	expect_that(WindowsRuntime.resolve_zig_in!("zig", "").is_err(), "a zig was found without PATH or ZIG")?
	older = fake_zig!("${dir}/older", "0.16.0")?
	match WindowsRuntime.resolve_zig_in!(older, "") {
		Err(Failed(message)) if message.contains("require Zig ${WindowsRuntime.zig_release.version}, found 0.16.0") => Ok({})
		other => Err(Failed("Zig 0.16.0 was not refused: ${Str.inspect(other)}"))
	}
}

# The compiler cache

## A crate whose build script compiles C with cc-rs, and a binary that
## checks the value the C code was compiled with.
compiler_cache_test! : Str, Str => Try({}, [Failed(Str), CommandFailed(Str, I32)])
compiler_cache_test! = |root, dir| {
	zig = Process.which!("zig") ? |_| Failed("The compiler cache check needs zig on PATH")
	cc_version = Cargo.lock_checksums(Files.read_text!("${root}/Cargo.lock")?).find_first(|(name, _, _)| name == "cc").map_ok(|(_, version, _)| version) ? |_| Failed("Cargo.lock has no cc package")
	# The adapter runs on the basic-cli release this script runs on.
	basic_cli = AppPlatformUrls.url_of(Files.read_text!("${root}/scripts/test_windows_runtime.roc")?) ? |NoPlatform| Failed("scripts/test_windows_runtime.roc declares no platform")
	Files.write_text!("${dir}/Cargo.toml", "[package]\nname = \"compiler_cache_regression\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[build-dependencies]\ncc = \"=${cc_version}\"\n")?
	Files.write_text!("${dir}/build.rs", "fn main() { cc::Build::new().file(\"sentinel.c\").compile(\"sentinel\"); }\n")?
	Files.write_text!("${dir}/sentinel.c", "int sentinel(void) { return VALUE; }\n")?
	Files.write_text!("${dir}/src/main.rs", "extern \"C\" { fn sentinel() -> i32; }\nfn main() { assert_eq!(unsafe { sentinel() }, std::env::args().nth(1).unwrap().parse::<i32>().unwrap()); }\n")?
	# The compiler the adapter is built for is a file whose contents are the
	# value the C code returns, so a new compiler gives a new value.
	selected = "${dir}/selected-compiler"
	Files.write_text!(selected, "1")?
	adapter = "ci/adapter.roc"
	Files.write_text!("${dir}/${adapter}", adapter_source(basic_cli, zig, Err(FromZig)))?
	values : List(I32)
	values = [1, 2, 3]
	for expected in values {
		if expected == 2 {
			Files.write_text!(selected, "2")?
		}
		if expected == 3 {
			Files.write_text!("${dir}/${adapter}", adapter_source(basic_cli, zig, Ok("3")))?
		}
		compiler = HostBuild.windows_compiler_in!(dir, selected, adapter)?
		cargo = Cmd.new(OsStr.from_str("cargo"))
			.args(["run", "--quiet", "--", expected.to_str()].map(OsStr.from_str))
			.cwd(Path.utf8(dir))
			.envs([("CC", compiler), ("ZIG", selected), ("CARGO_TARGET_DIR", "${dir}/target"), ("RUSTFLAGS", ""), ("CARGO_ENCODED_RUSTFLAGS", "")].map(|(key, value)| (OsStr.from_str(key), OsStr.from_str(value))))
			.inherit_stdio()
		ran = cargo.run!() ? |err| Failed("Could not run cargo: ${Str.inspect(err)}")
		expect_that(ran.status == Exited(0), "The C code was not rebuilt for compiler ${expected.to_str()}")?
		# A repeat keeps exactly the same compiler.
		expect_that(HostBuild.windows_compiler_in!(dir, selected, adapter)? == compiler, "The adapter's path changed without a change")?
	}
	# A cached adapter that changed after it was built is refused.
	compiler = HostBuild.windows_compiler_in!(dir, selected, adapter)?
	Files.write_bytes!(compiler, Files.read_bytes!(compiler)?.append(0))?
	match HostBuild.windows_compiler_in!(dir, selected, adapter) {
		Err(Failed(message)) if message.contains("changed after it was built") => Ok({})
		other => Err(Failed("A changed adapter was not refused: ${Str.inspect(other)}"))
	}
}

## An adapter on a basic-cli release that compiles with Zig for this
## machine, and defines VALUE as the contents of the file ZIG names, or as
## the fixed text given.
adapter_source : Str, Str, Try(Str, [FromZig]) -> Str
adapter_source = |basic_cli, zig, fixed| {
	(name, defined) =
		match fixed {
			Ok(text) => ("_value", text)
			Err(FromZig) => ("value", "\${value}")
		}
	Str.join_with(
		[
			"app [main!] {",
			"\tpf: platform \"${basic_cli}\",",
			"}",
			"",
			"import pf.Cmd",
			"import pf.Env",
			"import pf.OsStr",
			"import pf.Path",
			"",
			"main! = |raw_args| {",
			"\tselected = Env.var_str!(OsStr.from_str(\"ZIG\")) ?? \"\"",
			"\t${name} = (Path.utf8(selected).read_utf8!() ?? \"0\").trim()",
			"\targs = raw_args.map(|arg| OsStr.display(OsStr.from_raw(arg))).drop_if(|arg| arg.starts_with(\"--target=\"))",
			"\toutput = Cmd.new(OsStr.from_str(${Str.inspect(zig)})).args([\"cc\", \"-DVALUE=${defined}\"].concat(args).map(OsStr.from_str)).inherit_stdio().run!() ? |_| Exit(1)",
			"\tmatch output.status {",
			"\t\tExited(0) => Ok({})",
			"\t\t_ => Err(Exit(1))",
			"\t}",
			"}",
			"",
		],
		"\n",
	)
}

expect adapter_source("https://x/b.tar.zst", "/z/zig", Err(FromZig)).contains("\"-DVALUE=\${value}\"") and adapter_source("https://x/b.tar.zst", "/z/zig", Ok("3")).contains("\"-DVALUE=3\"") and adapter_source("https://x/b.tar.zst", "/z/zig", Ok("3")).contains("pf: platform \"https://x/b.tar.zst\"")
