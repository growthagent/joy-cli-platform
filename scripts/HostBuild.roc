import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path
import pf.Stdout
import Files
import Process
import Targets
import WindowsRuntime

## Builds the platform host for a target into platform/targets.
##
## The macOS and Linux hosts are built on either system. The Linux hosts are
## cross-compiled with `zig cc` when Zig is on PATH, which needs no musl
## cross toolchain. The Windows host is built on Windows only, with the
## runtime inputs of WindowsRuntime.
##
## Every path is taken from the repository root, the folder the scripts run
## in.
HostBuild := [].{

	## The adapter cc-rs runs as the C compiler of the Windows host.
	windows_adapter : Str
	windows_adapter = "ci/zig_msvc_cc.roc"

	## The Zig target of each musl Rust target.
	zig_musl_targets : List((Str, Str))
	zig_musl_targets = [
		("x86_64-unknown-linux-musl", "x86_64-linux-musl"),
		("aarch64-unknown-linux-musl", "aarch64-linux-musl"),
	]

	## The environment that lets cc-rs cross-compile C to musl with `zig cc`,
	## through ci/zig-cc.sh and ci/zig-ar.sh. Nothing when the target is not
	## musl or Zig is not on PATH. Prints a note when it uses Zig.
	musl_build_env! : Str => List((Str, Str))
	musl_build_env! = |rust_target| {
		root = Files.cwd!() ?? "."
		has_zig = Process.which!("zig").is_ok()
		cflags = Env.var_str!(OsStr.from_str("CFLAGS_${HostBuild.env_key(rust_target)}")) ?? ""
		env = HostBuild.musl_env(root, rust_target, has_zig, cflags)
		if !env.is_empty() {
			Stdout.line!("  (using zig cc for ${rust_target})") ?? {}
		}
		env
	}

	musl_env : Str, Str, Bool, Str -> List((Str, Str))
	musl_env = |root, rust_target, has_zig, cflags|
		match HostBuild.zig_musl_targets.find_first(|(rust, _)| rust == rust_target) {
			Ok((_, zig_target)) if has_zig => {
				key = HostBuild.env_key(rust_target)
				[
					("ZIG_CC_TARGET", zig_target),
					("CC_${key}", "${root}/ci/zig-cc.sh"),
					("AR_${key}", "${root}/ci/zig-ar.sh"),
					("CFLAGS_${key}", "${cflags} -Wno-error -fPIC"),
				]
			}
			_ => []
		}

	## A Rust target as cc-rs spells it in variable names.
	env_key : Str -> Str
	env_key = |rust_target| rust_target.replace_each("-", "_")

	## The separator of CARGO_ENCODED_RUSTFLAGS.
	flag_separator : Str
	flag_separator = "\u(1f)"

	## CARGO_ENCODED_RUSTFLAGS with one more flag. Cargo reads that variable in
	## place of RUSTFLAGS, so when it is not set the flags of RUSTFLAGS are
	## carried over, split on whitespace as Cargo splits them.
	with_rust_flag : Try(Str, [Null]), Str, Str -> Str
	with_rust_flag = |encoded, rustflags, flag| {
		existing =
			match encoded {
				Ok(flags) => flags
				Err(Null) => Str.join_with(HostBuild.words(rustflags), HostBuild.flag_separator)
			}
		if (existing.is_empty()) flag else "${existing}${HostBuild.flag_separator}${flag}"
	}

	## The words of a text, split on whitespace.
	words : Str -> List(Str)
	words = |text| text.split_on(" ").join_map(|part| part.split_on("\t")).join_map(|part| part.split_on("\n")).map(Str.trim).drop_if(Str.is_empty)

	rust_flags_env! : Str => (Str, Str)
	rust_flags_env! = |flag| {
		encoded = Env.var_str!(OsStr.from_str("CARGO_ENCODED_RUSTFLAGS")).map_err(|_| Null)
		rustflags = Env.var_str!(OsStr.from_str("RUSTFLAGS")) ?? ""
		("CARGO_ENCODED_RUSTFLAGS", HostBuild.with_rust_flag(encoded, rustflags, flag))
	}

	## Roc links every executable as PIE (roc-lang/roc#12949), so the host
	## and the C code it builds are position independent on every Unix
	## target.
	pic_build_env! : () => List((Str, Str))
	pic_build_env! = || [HostBuild.rust_flags_env!("-Crelocation-model=pic")]

	## The target rustc builds for when none is named.
	rust_host_target! : () => Try(Str, [Failed(Str)])
	rust_host_target! = || {
		info = Process.capture!(["rustc", "-vV"])?
		info.split_on("\n").keep_oks(|line| if (line.starts_with("host: ")) Ok(line.drop_prefix("host: ").trim()) else Err(NoHost)).first().map_err(|_| Failed("Could not determine the Rust host target"))
	}

	## llvm-strip from PATH, or from Rust's llvm-tools component.
	find_llvm_strip! : () => Try(Str, [Failed(Str)])
	find_llvm_strip! = || {
		match Process.which!("llvm-strip") {
			Ok(found) => return Ok(found)
			Err(_) => {}
		}
		sysroot = Files.posix(Process.capture!(["rustc", "--print", "sysroot"])?)
		suffix = if (Process.is_windows!()) ".exe" else ""
		candidate = "${sysroot}/lib/rustlib/${HostBuild.rust_host_target!()?}/bin/llvm-strip${suffix}"
		if Files.is_file!(candidate) {
			Ok(candidate)
		} else {
			Err(Failed("llvm-strip was not found. Install it with `rustup component add llvm-tools-preview`"))
		}
	}

	## Strips the debug data out of a macOS or Linux host. Rust's standard
	## library brings it along, and `strip = "debuginfo"` leaves it in a
	## static library.
	strip_host! : Str => Try({}, [Failed(Str), CommandFailed(Str, I32)])
	strip_host! = |target_name| {
		mode =
			if target_name.ends_with("musl") {
				# ELF's strip-unneeded mode keeps every symbol a relocation
				# refers to, and drops debug data and unused symbols.
				"--strip-unneeded"
			} else if target_name.ends_with("mac") {
				# Mach-O only loses its debug data, as the linker needs the
				# rest of a static library's symbols.
				"--strip-debug"
			} else {
				return Ok({})
			}
		path = "platform/targets/${target_name}/libhost.a"
		before = Files.size!(path)
		Process.run!([HostBuild.find_llvm_strip!()?, mode, path], [])?
		after = Files.size!(path)
		Stdout.line!("Stripped ${target_name} libhost.a: ${before.to_str()} -> ${after.to_str()} bytes") ?? {}
		Ok({})
	}

	## Whether rustc has the standard library of a target. rustc's complaint
	## about a target it does not know is not shown.
	rust_target_is_installed! : Str => Bool
	rust_target_is_installed! = |rust_target| {
		listed = Cmd.new(OsStr.from_str("rustc")).args(["--print", "target-libdir", "--target", rust_target].map(OsStr.from_str)).stderr(Null).capture!()
		match listed {
			Ok(dir) => Path.utf8(dir.trim()).is_dir!() ?? False
			Err(_) => False
		}
	}

	## Adds a Rust target with rustup when it is missing. A required target
	## that cannot be added stops the build, another one is only warned about.
	install_rust_target! : Str, Bool => Try({}, [Failed(Str), CommandFailed(Str, I32)])
	install_rust_target! = |rust_target, required| {
		if HostBuild.rust_target_is_installed!(rust_target) {
			return Ok({})
		}
		if Process.which!("rustup").is_err() {
			message = "Rust target ${rust_target} is not installed and rustup is unavailable. Enter `nix develop` or install the target manually"
			if required {
				return Err(Failed(message))
			}
			Stdout.line!("warning: ${message}") ?? {}
			return Ok({})
		}
		match Process.run!(["rustup", "target", "add", rust_target], []) {
			Ok({}) => Ok({})
			Err(err) => if (required) Err(err) else Ok({})
		}
	}

	copy_unix_host! : Str, Str, Bool => Try({}, [Failed(Str), CommandFailed(Str, I32)])
	copy_unix_host! = |target_name, rust_target, native| {
		source =
			if native and (target_name == "x64mac" or target_name == "arm64mac") {
				Process.run!(["cargo", "build", "--locked", "--release", "--lib"], HostBuild.pic_build_env!())?
				"target/release/libhost.a"
			} else {
				env = HostBuild.musl_build_env!(rust_target).concat(HostBuild.pic_build_env!())
				Process.run!(["cargo", "build", "--locked", "--release", "--lib", "--target", rust_target], env)?
				"target/${rust_target}/release/libhost.a"
			}
		destination = "platform/targets/${target_name}/libhost.a"
		Files.copy_file!(source, destination)?
		Stdout.line!("  -> ${destination}") ?? {}
		Ok({})
	}

	## Builds the host of a macOS or Linux target and copies it into
	## platform/targets. A native macOS host is built for the host's own
	## target.
	build_unix_target! : Str, Bool => Try({}, [Failed(Str), CommandFailed(Str, I32)])
	build_unix_target! = |target_name, native| {
		rust_target = Targets.rust_target_of(target_name) ? |_| Failed("Unknown target ${target_name}")
		qualifier = if (native) "native" else rust_target
		Stdout.line!("Building for ${target_name} (${qualifier})...") ?? {}
		HostBuild.copy_unix_host!(target_name, rust_target, native)?
		HostBuild.strip_host!(target_name)
	}

	## The name the adapter is built under for a compiler and adapter: it
	## changes with the Zig executable, its contents, the adapter's source and
	## the Roc that builds it.
	compiler_fingerprint : List(Str) -> Str
	compiler_fingerprint = |identity| Crypto.SHA256.hash(Str.join_with(identity, "\n").to_utf8()).to_hex()

	## The C compiler cc-rs runs for the Windows host: the adapter built from
	## ci/zig_msvc_cc.roc. See `windows_compiler_in!`.
	windows_compiler! : Str => Try(Str, [Failed(Str), CommandFailed(Str, I32)])
	windows_compiler! = |zig| HostBuild.windows_compiler_in!(Files.root!()?, zig, HostBuild.windows_adapter)

	## The adapter built from its source below `root` into
	## target/windows-compiler, in a folder named after its fingerprint.
	##
	## cc-rs tracks the value of CC, but not the contents of the program it
	## names or the environment the program reads. A new compiler or adapter
	## gets a new path, so cached ring and SQLite builds then rerun.
	##
	## The executable's hash is recorded next to it when it is built, and a
	## cached one that no longer has that hash is refused: a changed compiler
	## behind an unchanged path is what cc-rs cannot see.
	windows_compiler_in! : Str, Str, Str => Try(Str, [Failed(Str), CommandFailed(Str, I32)])
	windows_compiler_in! = |root, zig, adapter| {
		roc = Env.var_str!(OsStr.from_str("ROC")) ?? "roc"
		roc_version = Process.capture!([roc, "version"])?
		# The adapter is read once, so what is built is what the fingerprint
		# names.
		source = Files.read_bytes!("${root}/${adapter}")?
		identity = [zig, Files.sha256!(zig)?, Crypto.SHA256.hash(source).to_hex(), roc_version]
		directory = "${root}/target/windows-compiler/${HostBuild.compiler_fingerprint(identity)}"
		exe = if (Process.is_windows!()) ".exe" else ""
		executable = "${directory}/zig-msvc-cc${exe}"
		recorded = "${executable}.sha256"
		if !Files.is_file!(executable) or !Files.is_file!(recorded) {
			snapshot = "${directory}/${Files.base_name(adapter)}"
			Files.write_bytes!(snapshot, source)?
			building = "${directory}/zig-msvc-cc.building${exe}"
			# Without the compiler cache on Windows, as scripts/test.roc builds there.
			no_cache = if (Process.is_windows!()) ["--no-cache"] else []
			Process.run!([roc, "build", snapshot, "--output=${building}"].concat(no_cache), [])?
			Files.write_text!(recorded, Files.sha256!(building)?)?
			Path.utf8(building).rename!(Path.utf8(executable)) ? |err| Failed("Could not move ${building} to ${executable}: ${Str.inspect(err)}")
		}
		if Files.read_text!(recorded)? != Files.sha256!(executable)? {
			return Err(Failed("The compiler adapter was changed after it was built: ${executable}"))
		}
		Files.canonical!(executable)
	}

	## The environment that builds the Windows host, and the C compiler in it.
	##
	## The system UCRT import inputs match the standard dynamic CRT, so an
	## inherited +crt-static, which would bundle Microsoft CRT archives into
	## host.lib, is turned off. Other flags are kept.
	windows_build_env! : () => Try({ env : List((Str, Str)), compiler : Str, zig : Str }, [Failed(Str), CommandFailed(Str, I32)])
	windows_build_env! = || {
		zig = WindowsRuntime.resolve_zig!()?
		compiler = HostBuild.windows_compiler!(zig)?
		env = [
			("ZIG", zig),
			("CC_x86_64_pc_windows_msvc", compiler),
			HostBuild.rust_flags_env!("-Ctarget-feature=-crt-static"),
		]
		Ok({ env, compiler, zig })
	}

	## Builds host.lib and the runtime inputs into platform/targets/x64win,
	## and records them in its PROVENANCE.json.
	build_windows! : () => Try({}, [Failed(Str), CommandFailed(Str, I32)])
	build_windows! = || {
		Stdout.line!("Building for x64win (${Targets.windows_rust_target})...") ?? {}
		HostBuild.install_rust_target!(Targets.windows_rust_target, True)?
		{ env, compiler, zig } = HostBuild.windows_build_env!()?
		build_command = ["cargo", "build", "--locked", "--release", "--lib", "--target", Targets.windows_rust_target]
		Process.run!(build_command, env)?
		output_dir = "platform/targets/x64win"
		WindowsRuntime.build!(output_dir, zig)?
		host_destination = "${output_dir}/host.lib"
		Files.copy_file!("target/${Targets.windows_rust_target}/release/host.lib", host_destination)?
		Stdout.line!("  -> ${host_destination}") ?? {}
		c_compiler = Process.capture!([zig, "cc", "-target", "x86_64-windows-msvc", "--version"])?
		rust_flags = env.find_first(|(key, _)| key == "CARGO_ENCODED_RUSTFLAGS").map_ok(|(_, value)| value) ?? ""
		WindowsRuntime.record_host!(
			output_dir,
			[build_command],
			[
				("c_compiler", "zig cc\n${c_compiler}"),
				("zig_executable_sha256", Files.sha256!(zig)?),
				("c_runtime_flags", "-fms-runtime-lib=dll"),
				("rust_flags", rust_flags),
				("c_compiler_env", "CC_x86_64_pc_windows_msvc=${compiler}"),
			],
		)
	}
}

# Tests. They run through an app that imports this module:
# `roc test scripts/build.roc`.

expect HostBuild.musl_env("/repo", "x86_64-unknown-linux-musl", True, "") == [("ZIG_CC_TARGET", "x86_64-linux-musl"), ("CC_x86_64_unknown_linux_musl", "/repo/ci/zig-cc.sh"), ("AR_x86_64_unknown_linux_musl", "/repo/ci/zig-ar.sh"), ("CFLAGS_x86_64_unknown_linux_musl", " -Wno-error -fPIC")]
expect HostBuild.musl_env("/repo", "aarch64-unknown-linux-musl", True, "-O1") == [("ZIG_CC_TARGET", "aarch64-linux-musl"), ("CC_aarch64_unknown_linux_musl", "/repo/ci/zig-cc.sh"), ("AR_aarch64_unknown_linux_musl", "/repo/ci/zig-ar.sh"), ("CFLAGS_aarch64_unknown_linux_musl", "-O1 -Wno-error -fPIC")]
expect HostBuild.musl_env("/repo", "x86_64-unknown-linux-musl", False, "") == []
expect HostBuild.musl_env("/repo", "aarch64-apple-darwin", True, "") == []

# Inherited Rust flags are kept and the dynamic CRT is selected.
expect HostBuild.with_rust_flag(Ok("-Ctarget-feature=+crt-static\u(1f)-Cdebuginfo=1"), "", "-Ctarget-feature=-crt-static").split_on("\u(1f)") == ["-Ctarget-feature=+crt-static", "-Cdebuginfo=1", "-Ctarget-feature=-crt-static"]
expect HostBuild.with_rust_flag(Err(Null), "  -Cdebuginfo=1 \t  -Copt-level=2\n", "-Ctarget-feature=-crt-static").split_on("\u(1f)") == ["-Cdebuginfo=1", "-Copt-level=2", "-Ctarget-feature=-crt-static"]
expect HostBuild.with_rust_flag(Err(Null), "", "-Crelocation-model=pic") == "-Crelocation-model=pic"
expect HostBuild.with_rust_flag(Ok(""), "-Cignored", "-Crelocation-model=pic") == "-Crelocation-model=pic"

# The adapter's name changes with each part of its identity.
expect {
	base = HostBuild.compiler_fingerprint(["/zig", "aa", "bb", "roc 1"])
	base == HostBuild.compiler_fingerprint(["/zig", "aa", "bb", "roc 1"])
		and base != HostBuild.compiler_fingerprint(["/zig", "ab", "bb", "roc 1"])
		and base != HostBuild.compiler_fingerprint(["/zig", "aa", "bc", "roc 1"])
		and base != HostBuild.compiler_fingerprint(["/zig", "aa", "bb", "roc 2"])
		and base != HostBuild.compiler_fingerprint(["/zig2", "aa", "bb", "roc 1"])
}
