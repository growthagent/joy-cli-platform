import pf.Path
import pf.Stdout
import Files
import Process
import Targets
import WindowsRuntime

## Bundles the platform with `roc bundle`, for scripts/bundle.roc.
##
## The bundle holds the platform's .roc files, the inputs of every target
## platform/main.roc declares, the macOS link stubs, the Windows provenance
## and notices, and at its root LICENSE, THIRD_PARTY_LICENSES.md and Rust's
## standard library notices as COPYRIGHT-rust-library.html. Those three are
## copied into platform/ for `roc bundle` and put back as they were after.
PlatformBundle := [].{

	Options : { output_dir : Str, stub_missing_targets : Bool, roc_args : List(Str) }

	## Runs `roc bundle` with its arguments in a folder.
	Runner : Str, List(Str) => Try({}, [Failed(Str), CommandFailed(Str, I32)])

	## Roc's default limit on a platform's unpacked size.
	max_platform_bytes : U64
	max_platform_bytes = 100 * 1024 * 1024

	## The inputs each target in a platform header declares, by their path in
	## platform/.
	declared_inputs : Str -> List(Str)
	declared_inputs = |source| Targets.declared(source).join_map(|(target, names)| names.map(|name| "targets/${target}/${name}"))

	## main.roc first, as `roc bundle` takes the first file as the entry point.
	platform_order : Str, Str -> [Before, Same, After]
	platform_order = |a, b|
		match (a == "main.roc", b == "main.roc") {
			(True, False) => Before
			(False, True) => After
			_ => Files.compare(a, b)
		}

	## Bundles the platform of the repository at `root` into the output
	## folder, relative to `root` unless it is absolute. With
	## `stub_missing_targets`, declared inputs that were not built are empty
	## files for the run.
	run! : Str, PlatformBundle.Options, PlatformBundle.Runner => Try({}, [Failed(Str), CommandFailed(Str, I32)])
	run! = |root, options, runner!| {
		platform_dir = "${root}/platform"
		declared = PlatformBundle.declared_inputs(Files.read_text!("${platform_dir}/main.roc")?)
		# `roc bundle` needs every declared target input. A test bundle only
		# needs the native host, so other targets get empty files for the run.
		stubs =
			if options.stub_missing_targets {
				declared.fold_try!(
					[],
					|made, relative| {
						path = "${platform_dir}/${relative}"
						if Path.utf8(path).exists!() ?? True {
							return Ok(made)
						}
						Files.write_bytes!(path, [])?
						Ok(made.append(path))
					},
				)?
			} else {
				[]
			}
		result = PlatformBundle.bundle!(root, options, declared, runner!)
		for path in stubs {
			_ = Path.utf8(path).delete!()
		}
		result
	}

	bundle! : Str, PlatformBundle.Options, List(Str), PlatformBundle.Runner => Try({}, [Failed(Str), CommandFailed(Str, I32)])
	bundle! = |root, options, declared, runner!| {
		platform_dir = "${root}/platform"
		given = Files.posix(options.output_dir)
		output_dir = if (given.starts_with("/") or (given.split_on("/").first() ?? "").contains(":")) given else "${root}/${given}"
		Files.make_dir!(output_dir)?
		resolved_output = Files.canonical!(output_dir)?

		entries = Path.utf8(platform_dir).list!() ? |err| Failed("Could not read ${platform_dir}: ${Str.inspect(err)}")
		roc_names = entries.map(|entry| Files.base_name(Path.display(entry))).keep_if(|name| name.ends_with(".roc"))
		roc_files = roc_names.fold_try!([], |kept, name| Ok(if (Files.is_file!("${platform_dir}/${name}")) kept.append(name) else kept))?.sort_with(PlatformBundle.platform_order)

		# Only declared targets ship, so a stray host for another target stays out.
		declared_dirs = Files.unique(declared.map(Files.parent_of))
		library_files = Files.files_under!("${platform_dir}/targets")?
			.map(|path| "targets/${path}")
			.keep_if(|path| WindowsRuntime.is_binary(path) and declared_dirs.any(|dir| path.starts_with("${dir}/")))
		# The macOS sysroot gives the linker the frameworks the host links.
		link_stubs = Files.files_under!("${platform_dir}/targets/macos-sysroot")?.keep_if(|path| path.ends_with(".tbd")).map(|path| "targets/macos-sysroot/${path}")
		libraries = library_files.concat(link_stubs)
		filled! = |relative| Files.is_file!("${platform_dir}/${relative}") and Files.size!("${platform_dir}/${relative}") > 0

		if !options.stub_missing_targets {
			missing = declared.fold_try!([], |found, path| Ok(if (filled!(path)) found else found.append(path)))?
			if !missing.is_empty() {
				return Err(Failed("Missing or empty platform inputs: ${Str.join_with(missing, ", ")}"))
			}
		}
		windows_dir = "targets/x64win"
		incomplete_windows = WindowsRuntime.libraries.append("host.lib").fold_try!(False, |incomplete, name| Ok(incomplete or !filled!("${windows_dir}/${name}")))?
		metadata_files =
			if declared_dirs.contains(windows_dir) and !(options.stub_missing_targets and incomplete_windows) {
				WindowsRuntime.validate!("${platform_dir}/${windows_dir}", True)?.map(|path| "${windows_dir}/${path}")
			} else {
				[]
			}
		bundle_files = roc_files.concat(libraries).concat(metadata_files)

		# A local test bundle may go without Rust's notices when rust-docs is
		# not installed. A release bundle never does.
		rust_notices = PlatformBundle.rust_library_notices!()?
		missing_notices = "Rust's standard library notices are missing: ${rust_notices}. They come with Rust's rust-docs component, which the nix dev shell has. With rustup, run `rustup component add rust-docs`"
		license_sources =
			[("${root}/THIRD_PARTY_LICENSES.md", "THIRD_PARTY_LICENSES.md"), ("${root}/LICENSE", "LICENSE")].concat(
				if Files.is_file!(rust_notices) {
					[(rust_notices, "COPYRIGHT-rust-library.html")]
				} else if options.stub_missing_targets {
					Stdout.line!("warning: ${missing_notices}. This test bundle goes without them.") ?? {}
					[]
				} else {
					return Err(Failed(missing_notices))
				},
			)
		var $unpacked_size = 0
		for path in bundle_files.map(|relative| "${platform_dir}/${relative}").concat(license_sources.map(|(source, _)| source)) {
			$unpacked_size = $unpacked_size + Files.size!(path)
		}
		unpacked_size = $unpacked_size
		if unpacked_size > PlatformBundle.max_platform_bytes {
			return Err(Failed("Platform inputs exceed Roc's default 100 MiB transitive dependency limit: ${unpacked_size.to_str()} bytes"))
		}

		Stdout.line!("Bundling ${roc_files.len().to_str()} .roc files and ${libraries.len().to_str()} library files...\n") ?? {}
		Stdout.line!("Files to bundle:") ?? {}
		for path in bundle_files.concat(license_sources.map(|(_, name)| name)) {
			Stdout.line!("  ${path}") ?? {}
		}
		Stdout.line!("Unpacked platform size: ${unpacked_size.to_str()} bytes\n") ?? {}

		# Each license file goes into platform/ for the run, and whatever was
		# there before is put back after it, whether the bundle succeeded or not.
		backups = license_sources.fold_try!(
			[],
			|saved, (_, name)| {
				destination = "${platform_dir}/${name}"
				before = if (Files.is_file!(destination)) Ok(Files.read_bytes!(destination)?) else Err(Absent)
				Ok(saved.append((destination, before)))
			},
		)?
		copied = license_sources.fold_try!({}, |{}, (source, name)| Files.copy_file!(source, "${platform_dir}/${name}"))
		result =
			match copied {
				Ok({}) => runner!(platform_dir, ["bundle"].concat(bundle_files).concat(license_sources.map(|(_, name)| name)).concat(["--output-dir", resolved_output]).concat(options.roc_args))
				Err(err) => Err(err)
			}
		for (destination, before) in backups {
			match before {
				Ok(bytes) => {
					_ = Path.utf8(destination).write_bytes!(bytes)
				}
				Err(Absent) => {
					_ = Path.utf8(destination).delete!()
				}
			}
		}
		result
	}

	## Where Rust's notices for its standard library are, which every host
	## links. They come with Rust's rust-docs component.
	rust_library_notices! : () => Try(Str, [Failed(Str)])
	rust_library_notices! = || Ok("${Files.posix(Process.capture!(["rustc", "--print", "sysroot"])?)}/share/doc/rust/COPYRIGHT-library.html")
}

# The Windows inputs a platform declares are the ones the runtime build makes.
expect {
	declared = PlatformBundle.declared_inputs("\t\tx64musl: { inputs: [\"rcrt1.o\", app] },\n\t\tx64win: { inputs: [\"host.lib\", app, \"windows_support.lib\"] }\n")
	windows = declared.keep_if(|path| path.starts_with("targets/x64win/")).map(Files.base_name)
	declared.contains("targets/x64musl/rcrt1.o") and windows.sort_with(Files.compare) == WindowsRuntime.libraries.append("host.lib").sort_with(Files.compare)
}

expect ["Path.roc", "main.roc", "Cmd.roc"].sort_with(PlatformBundle.platform_order) == ["main.roc", "Cmd.roc", "Path.roc"]
