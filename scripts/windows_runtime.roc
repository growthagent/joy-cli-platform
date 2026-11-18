#!/usr/bin/env roc
app [main!] {
	pf: platform "https://github.com/niclas-ahden/basic-cli/releases/download/0.32.0/3MnQnCrtfe6XS5qx58MnAGU6iWk8i1N24MYfoejcWeax.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.10.2/7CdYzjBAJmprmnK45oTpmH6BXt76ZASN2Ck5uZQEoWsK.tar.zst",
}

import pf.Cmd
import pf.Duration
import pf.OsStr
import pf.Stdout
import weaver.Cli
import weaver.Opt
import CommandLine
import Files
import HostBuild
import Process
import WindowsRuntime

## Builds the redistributable MSVC inputs of the Windows host into
## platform/targets/x64win, or another folder, and never copies a Microsoft
## SDK library. See WindowsRuntime.roc.
##
## Run it from the repository root:
##
##     roc scripts/windows_runtime.roc [--output-dir DIR] [--check]
##
## `--check` builds nothing and checks the folder's PROVENANCE.json against
## its files, the host included.
##
## `--test-windows` runs the checks that need Windows, after
## `roc scripts/build.roc --target x64win`: the TLS test of the host built
## with the production compiler and profile, and executables linked from the
## inputs, which must not import the VC runtime and must start, run their
## initializers and check their stack cookie.
##
## A failed command ends the script with the command's exit code.
## `roc test scripts/windows_runtime.roc` runs the tests that need neither.
main! : _ => Try({}, _)
main! = |raw_args| {
	args = CommandLine.read!(cli, raw_args)?
	Process.finish!(run!(args.output_dir ?? "platform/targets/x64win", args.check, args.test_windows))
}

cli = Cli.finish_without_validating(
	{
		output_dir: Opt.maybe_str({ short: "", long: "output-dir", help: "The folder of the inputs, platform/targets/x64win by default." }),
		check: Opt.flag({ short: "", long: "check", help: "Check the folder's PROVENANCE.json instead of building." }),
		test_windows: Opt.flag({ short: "", long: "test-windows", help: "Run the executable checks of the built inputs (Windows only)." }),
	}.Cli,
	CommandLine.config({ name: "windows_runtime.roc", description: "Build redistributable MSVC inputs, and never copy Microsoft SDK libraries." }),
)

run! : Str, Bool, Bool => Try({}, [Failed(Str), CommandFailed(Str, I32)])
run! = |output_dir, check, test| {
	_ = Files.root!()?
	if test {
		test_windows!(output_dir)
	} else if check {
		_ = WindowsRuntime.validate!(output_dir, True)?
		Ok({})
	} else {
		zig = WindowsRuntime.resolve_zig!()?
		WindowsRuntime.build!(output_dir, zig)
	}
}

# Checks on Windows

test_windows! : Str => Try({}, [Failed(Str), CommandFailed(Str, I32)])
test_windows! = |inputs| {
	if !Process.is_windows!() {
		return Err(Failed("--test-windows runs on Windows only"))
	}
	WindowsRuntime.check!("TLS with the production compiler and profile", || tls_test!())?
	WindowsRuntime.check!("the host links without SDK or VC runtime archives", || host_link_test!(inputs))?
	WindowsRuntime.check!("startup, TLS, initializers, stack cookie and type info", || startup_test!(inputs))?
	Stdout.line!("All Windows checks passed") ?? {}
	Ok({})
}

tls_test! : () => Try({}, [Failed(Str), CommandFailed(Str, I32)])
tls_test! = || {
	{ env, .. } = HostBuild.windows_build_env!()?
	Process.run!(["cargo", "test", "--locked", "--release", "--lib", "--target", "x86_64-pc-windows-msvc", "http::tests::ring_tls_handshake_and_untrusted_certificate_rejection"], env)
}

host_link_test! : Str => Try({}, [Failed(Str), CommandFailed(Str, I32)])
host_link_test! = |inputs| {
	_ = WindowsRuntime.validate!(inputs, True)?
	zig = WindowsRuntime.resolve_zig!()?
	scratch = "target/windows-host-fixture"
	source = "${scratch}/app.c"
	# MSVC passes this RocList argument indirectly. The smoke app ignores it.
	Files.write_text!(source, "int roc_main(void *args) { (void)args; return 37; }\n")?
	obj = "${scratch}/app.obj"
	exe = "${scratch}/app.exe"
	Process.run!([zig, "cc", "-target", "x86_64-windows-msvc", "-c", source, "-o", obj], [])?
	Process.run!([zig, "lld-link", "/nodefaultlib", "/subsystem:console", "/entry:mainCRTStartup", "/machine:x64", "/opt:ref", "/out:${exe}", obj, "${inputs}/host.lib"].concat(WindowsRuntime.libraries.map(|name| "${inputs}/${name}")), [])?
	no_vc_runtime!(exe)?
	expect_exit!(exe, [], |code| code == 37, "37")
}

startup_test! : Str => Try({}, [Failed(Str), CommandFailed(Str, I32)])
startup_test! = |inputs| {
	_ = WindowsRuntime.validate!(inputs, True)?
	zig = WindowsRuntime.resolve_zig!()?
	scratch = "target/windows-runtime-fixture"
	Files.make_dir!(scratch)?
	for fail_initializer in [False, True] {
		obj = "${scratch}/fixture.obj"
		exe = "${scratch}/fixture.exe"
		compile = [zig, "cc", "-target", "x86_64-windows-msvc", "-O2", "-fstack-protector-strong", "-c", "${WindowsRuntime.source_dir}/runtime_fixture.c", "-o", obj]
		Process.run!(if (fail_initializer) compile.append("-DFAIL_INITIALIZER") else compile, [])?
		Process.run!([zig, "lld-link", "/nodefaultlib", "/subsystem:console", "/entry:mainCRTStartup", "/machine:x64", "/opt:ref", "/out:${exe}", obj].concat(WindowsRuntime.libraries.map(|name| "${inputs}/${name}")), [])?
		no_vc_runtime!(exe)?
		if fail_initializer {
			expect_exit!(exe, ["a b"], |code| code == 255, "255")?
		} else {
			expect_exit!(exe, ["a b"], |code| code == 37, "37")?
			# A failed stack cookie check ends the process with STATUS_STACK_BUFFER_OVERRUN.
			expect_exit!(exe, ["fail"], |code| code.to_u32_wrap() == 0xC0000409, "0xc0000409")?
		}
	}
	Ok({})
}

## Refuses an executable that imports the VC runtime or the C++ library.
no_vc_runtime! : Str => Try({}, [Failed(Str), CommandFailed(Str, I32)])
no_vc_runtime! = |exe| {
	strip = HostBuild.find_llvm_strip!()?
	readobj = "${Files.parent_of(Files.posix(strip))}/llvm-readobj.exe"
	imported = Process.capture!([readobj, "--coff-imports", exe])?.with_ascii_lowercased()
	if imported.contains("vcruntime") or imported.contains("msvcp") {
		Err(Failed("${exe} imports the VC runtime:\n${imported}"))
	} else {
		Ok({})
	}
}

expect_exit! : Str, List(Str), (I32 -> Bool), Str => Try({}, [Failed(Str), CommandFailed(Str, I32)])
expect_exit! = |exe, args, wanted, shown| {
	output = Cmd.new(OsStr.from_str(exe)).args(args.map(OsStr.from_str)).timeout(Duration.seconds(20)).run!() ? |err| Failed("Could not run ${exe}: ${Str.inspect(err)}")
	match output.status {
		Exited(code) if wanted(code) => Ok({})
		status => Err(Failed("${exe} ${Str.join_with(args, " ")} ended with ${Str.inspect(status)}, expected exit code ${shown}"))
	}
}
