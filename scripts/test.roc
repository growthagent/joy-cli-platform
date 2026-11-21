#!/usr/bin/env roc
app [main!] {
	pf: platform "https://github.com/niclas-ahden/basic-cli/releases/download/0.32.0/3MnQnCrtfe6XS5qx58MnAGU6iWk8i1N24MYfoejcWeax.tar.zst",
	re: "https://github.com/niclas-ahden/roc-regex/releases/download/0.1.1/csQ1GrMfexbXbQLwhGfS8VE5bw3aooEFm82Nkd4UCvc.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.10.2/7CdYzjBAJmprmnK45oTpmH6BXt76ZASN2Ck5uZQEoWsK.tar.zst",
}

import pf.Cmd
import pf.Duration
import pf.Env
import pf.Monotonic
import pf.OsStr
import pf.Path
import pf.Signal
import pf.Sleep
import pf.Stderr
import pf.Stdout
import pf.System
import pf.Tcp
import re.Regex
import weaver.Cli
import weaver.Opt
import AppPlatformUrls
import CommandLine
import Files
import JsonValue
import Process
import Targets

## Builds and tests the platform against a bundle, driven by
## scripts/test_spec.json:
##
##     roc scripts/test.roc [--bundle-path BUNDLE | --bundle-url URL] [--no-build]
##         [--operation all|validate|build|run] [--target TARGET]
##         [--artifact-dir DIR] [--valgrind]
##
## Without a bundle it builds the platform for the target, bundles it and
## serves the bundle over HTTP while the suite runs. The suite points every
## app at the bundle and puts the apps back afterwards. `validate` runs the
## Rust and platform tests and checks, formats and tests every app, `build`
## builds every app into the artifact folder with a manifest and, for this
## machine's target, runs one from its source as `roc app.roc` does, and `run`
## runs the cases of every app from the artifact folder on this machine.
##
## Run it from the repository or a folder in it. It builds tools/test-helper
## with cargo, which runs apps on a terminal of their own and serves the
## bundle. `roc test scripts/test.roc` runs the tests at the bottom.
main! : _ => Try({}, _)
main! = |raw_args| {
	args = CommandLine.read!(cli, raw_args)?
	match run!(args) {
		Ok(message) => {
			Stdout.line!("\n=== ${message}! ===") ?? {}
			Ok({})
		}
		Err(Usage(message)) => CommandLine.fail!(cli, message)
		Err(Failed(message)) => Process.finish!(Err(Failed(message)))
		Err(CommandFailed(command, code)) => Process.finish!(Err(CommandFailed(command, code)))
		Err(Interrupted) => Err(Interrupted)
	}
}

cli = Cli.finish_without_validating(
	{
		bundle_path: Opt.maybe_str({ short: "", long: "bundle-path", help: "Test this bundle instead of building one." }),
		bundle_url: Opt.maybe_str({ short: "", long: "bundle-url", help: "Test the bundle at this URL instead of building one, BUNDLE_URL by default." }),
		no_build: Opt.flag({ short: "", long: "no-build", help: "Use the host inputs already built. NO_BUILD=1 does the same." }),
		operation: CommandLine.choice({ long: "operation", help: "validate, build or run, or all of them (the default).", choices: ["all", "validate", "build", "run"] }),
		target: Opt.maybe_str({ short: "", long: "target", help: "The Roc target, this machine's by default." }),
		artifact_dir: Opt.maybe_str({ short: "", long: "artifact-dir", help: "The folder of the built examples, dist/example-binaries by default." }),
		valgrind: Opt.flag({ short: "", long: "valgrind", help: "Run the example cases under valgrind." }),
	}.Cli,
	CommandLine.config({ name: "test.roc", description: "Build and test the platform against a bundle." }),
)

Options : { bundle_path : Try(Str, [NoValue]), bundle_url : Try(Str, [NoValue]), no_build : Bool, operation : Try(Str, [NoValue]), target : Try(Str, [NoValue]), artifact_dir : Try(Str, [NoValue]), valgrind : Bool }

## Why the script stops: a message, a command that failed with its exit
## code, a wrong command line, or Ctrl+C.
Problem : [Failed(Str), CommandFailed(Str, I32), Usage(Str), Interrupted]

stages : List(Str)
stages = ["fmt", "check", "test", "build", "run"]

## A case with "live_handles": N sets this, making the host report at exit
## how many native resource handles are still open, and requires the total to
## be N.
live_handles_env : Str
live_handles_env = "BASIC_CLI_LIVE_HANDLES"

## What every step needs to know about this machine and the checkout.
Ctx : {
	root : Str,
	windows : Bool,

	## The system: linux, darwin or windows.
	system : Str,
	roc : Str,

	## Whether roc runs here without its compiler cache.
	no_cache : Bool,

	## tools/test-helper's binary.
	helper : Str,
}

run! : Options => Try(Str, Problem)
run! = |args| {
	ctx = context!()?
	declared = declared_targets!(ctx)?
	operation = args.operation ?? "all"
	bundle_path = args.bundle_path
	bundle_url =
		match args.bundle_url {
			Ok(url) => Ok(url)
			Err(NoValue) => env_text!("BUNDLE_URL").map_err(|Unset| NoValue)
		}
	no_build = args.no_build or env_text!("NO_BUILD") == Ok("1")
	valgrind = args.valgrind
	match args.target {
		Ok(chosen) if !declared.contains(chosen) => return Err(Usage("--target: '${chosen}' is not one of ${Str.join_with(declared, ", ")}"))
		_ => {}
	}
	if bundle_path.is_ok() and bundle_url.is_ok() {
		return Err(Usage("--bundle-path and --bundle-url are mutually exclusive"))
	}
	native = Targets.native!()?
	target = args.target ?? native
	if !declared.contains(target) {
		return Err(Failed("platform/main.roc does not declare the ${target} target"))
	}
	artifact_dir =
		match args.artifact_dir {
			Ok(dir) => absolute!(ctx, dir)?
			Err(NoValue) => join(ctx, "dist/example-binaries")
		}
	if valgrind and !Cmd.check_available!("valgrind") {
		return Err(Usage("--valgrind requires 'valgrind' on PATH"))
	}
	if valgrind and operation != "all" and operation != "run" {
		return Err(Usage("--valgrind requires an operation that runs example cases"))
	}
	catch_signals!()
	build_helper!(ctx)?
	if operation == "run" {
		if target != native {
			return Err(Failed("Cannot run ${target} artifacts on native target ${native}"))
		}
		run_artifact_cases!(ctx, target, artifact_dir, valgrind)?
		return Ok("All native run cases passed")
	}
	if !Cmd.check_available!(ctx.roc) {
		return Err(Failed("Roc executable '${ctx.roc}' was not found"))
	}
	version = Cmd.new(OsStr.from_str(ctx.roc)).arg("version").capture!() ? |err| Failed("roc version failed: ${Str.inspect(err)}")
	Stdout.line!("Using roc version: ${version.trim()}") ?? {}
	if !no_build and bundle_path.is_err() {
		Stdout.line!("\n=== Building platform ===") ?? {}
		Process.call!(script(ctx, "build").concat(["--target", target]), ctx.root)?
	}
	operations =
		match operation {
			"all" => ["validate", "build", "run"]
			"validate" => ["validate"]
			_ => ["build"]
		}
	if operations.contains("run") and target != native {
		return Err(Failed("Cannot run ${target} artifacts on native target ${native}"))
	}
	scratch = valgrind_scratch!(valgrind)?
	suite = { operations, target, artifact_dir, valgrind, scratch }
	result =
		match bundle_url {
			Ok(url) => {
				Stdout.line!("\n=== Using provided bundle ===\nBundle: ${url}") ?? {}
				run_suite!(ctx, url, suite)
			}
			Err(NoValue) => with_bundle!(ctx, bundle_path, suite)
		}
	# Signals caught while the suite ran are answered by stopping here.
	_ = Signal.poll!()
	remove_scratch!(scratch)
	cleanup_test_files!(ctx)
	result?
	Ok(
		match operation {
			"all" => "All native checks and run cases passed"
			"validate" => "All source validation stages passed"
			_ => "All examples built for ${target}"
		},
	)
}

## Catches Ctrl+C, and SIGTERM on Unix, so an interrupted suite still puts
## the apps back. The command that was running gets the signal too.
catch_signals! : () => {}
catch_signals! = || {
	_ =
		match System.target!().os() {
			Linux(linux) => Signal.catch!([Interrupt, Terminate(linux.unix())])
			MacOS(macos) => Signal.catch!([Interrupt, Terminate(macos.unix())])
			Windows(_) => Signal.catch!([Interrupt])
		}
	{}
}

## The repository root: the folder this runs in, or the nearest one above it
## that holds scripts/test_spec.json and platform/main.roc.
context! : () => Try(Ctx, Problem)
context! = || {
	cwd = Files.cwd!()?
	windows = Process.is_windows!()
	target = System.target!()
	system =
		match target.os() {
			Windows(_) => "windows"
			MacOS(_) => "darwin"
			Linux(_) => "linux"
		}
	root = Files.find_root!(cwd, ["scripts/test_spec.json", "platform/main.roc"]) ? |NoRoot| Failed("Run scripts/test.roc from the repository: no scripts/test_spec.json and platform/main.roc here or above")
	roc = env_text!("ROC") ?? "roc"
	exe = if (windows) ".exe" else ""
	helper = native_join(windows, root, "tools/test-helper/target/release/test-helper${exe}")
	Ok({ root, windows, system, roc, no_cache: windows, helper })
}

env_text! : Str => Try(Str, [Unset])
env_text! = |name|
	match Env.var_str!(OsStr.from_str(name)) {
		Ok(value) => Ok(value)
		Err(_) => Err(Unset)
	}

## Joins a path inside the repository, written with `/`, to a folder, with
## the separator of this machine.
native_join : Bool, Str, Str -> Str
native_join = |windows, dir, relative|
	if windows {
		"${dir.drop_suffix("\\")}\\${relative.replace_each("/", "\\")}"
	} else {
		"${dir.drop_suffix("/")}/${relative}"
	}

join : Ctx, Str -> Str
join = |ctx, relative| native_join(ctx.windows, ctx.root, relative)

is_absolute : Bool, Str -> Bool
is_absolute = |windows, path|
	if windows {
		bytes = path.to_utf8()
		match bytes {
			[letter, ':', ..] if (letter >= 'A' and letter <= 'Z') or (letter >= 'a' and letter <= 'z') => True
			['\\', ..] | ['/', ..] => True
			_ => False
		}
	} else {
		path.starts_with("/")
	}

## A path given on the command line, relative to the current directory.
absolute! : Ctx, Str => Try(Str, Problem)
absolute! = |ctx, path|
	if is_absolute(ctx.windows, path) {
		Ok(path)
	} else {
		cwd = Env.cwd!() ? |_| Failed("The current directory is not available")
		Ok(native_join(ctx.windows, Path.display(cwd), path))
	}

## The targets platform/main.roc declares, each of which Targets.roc knows.
declared_targets! : Ctx => Try(List(Str), Problem)
declared_targets! = |ctx| {
	text = Files.read_text!(join(ctx, "platform/main.roc"))?
	found = Targets.declared(text).map(|(name, _)| name)
	if found.is_empty() {
		return Err(Failed("platform/main.roc: no platform targets found"))
	}
	unknown = found.drop_if(|name| Targets.roc_names.contains(name))
	if !unknown.is_empty() {
		return Err(Failed("platform/main.roc declares targets scripts/Targets.roc does not know: ${Str.inspect(unknown)}"))
	}
	Ok(found)
}

# Commands

## An exit status as the spec states it: the exit code, or minus the signal.
status_number : Cmd.ExitStatus -> I32
status_number = |status|
	match status {
		Exited(code) => code
		Signaled(signal) => 0 - signal
	}

## How to run a sibling script, with the same roc.
script : Ctx, Str -> List(Str)
script = |ctx, name| [ctx.roc].concat(no_cache_args(ctx)).append(join(ctx, "scripts/${name}.roc"))

## Windows checks, tests and builds go without the compiler cache. basic-cli
## has done so since its first Windows CI (its commit 5c21791), with no reason
## recorded, and scripts/HostBuild.roc builds the compiler adapter the same
## way.
no_cache_args : Ctx -> List(Str)
no_cache_args = |ctx| if (ctx.no_cache) ["--no-cache"] else []

roc_extra_args : Ctx -> List(Str)
roc_extra_args = |ctx| ["--max-transitive-mb=256"].concat(no_cache_args(ctx))

## Builds tools/test-helper, which runs apps on a terminal and serves bundles.
build_helper! : Ctx => Try({}, Problem)
build_helper! = |ctx| {
	dir = join(ctx, "tools/test-helper")
	Process.call!(["cargo", "build", "--locked", "--release", "--target-dir", native_join(ctx.windows, dir, "target")], dir)
}

# Bundles

## Builds a bundle unless one is given, serves it over HTTP and runs the
## suite against it.
with_bundle! : Ctx, Try(Str, [NoValue]), Suite => Try({}, Problem)
with_bundle! = |ctx, given, suite| {
	(bundle, generated) =
		match given {
			Ok(path) => (absolute!(ctx, path)?, False)
			Err(NoValue) => {
				Stdout.line!("\n=== Bundling platform ===") ?? {}
				(create_bundle!(ctx)?, True)
			}
		}
	if !(Path.utf8(bundle).is_file!() ?? False) {
		return Err(Failed("Bundle does not exist: ${bundle}"))
	}
	result = serve_bundle!(ctx, bundle, suite)
	if generated {
		Path.utf8(bundle).delete!() ?? {}
	}
	result
}

serve_bundle! : Ctx, Str, Suite => Try({}, Problem)
serve_bundle! = |ctx, bundle, suite| {
	(dir, name) = Files.split_path(bundle)
	server = Cmd.new(OsStr.from_str(ctx.helper))
		.args(["serve", dir].map(OsStr.from_str))
		.stdin(Null)
		.stdout(Pipe)
		.spawn_leashed!() ? |err| Failed("could not start the bundle server: ${Str.inspect(err)}")
	base = first_line!(server, [])?
	url = "${base}/${name}"
	result =
		match head!(url) {
			Ok({}) => {
				Stdout.line!("Bundle: ${url}") ?? {}
				run_suite!(ctx, url, suite)
			}
			Err(problem) => Err(problem)
		}
	server.close!() ?? {}
	result
}

## The first line the server prints: its address.
first_line! : Cmd.Child, List(U8) => Try(Str, Problem)
first_line! = |server, so_far|
	match so_far.split_first('\n') {
		Ok({ before, .. }) => Ok(Str.from_utf8_lossy(before).trim())
		Err(_) =>
			match server.read!(Duration.seconds(10)) {
				Ok(Stdout(bytes)) => first_line!(server, so_far.concat(bytes))
				Ok(Stderr(bytes)) => first_line!(server, so_far.concat(bytes))
				Err(Interrupted) => Err(Interrupted)
				Err(err) => Err(Failed("The bundle server did not start: ${Str.inspect(err)}"))
			}
	}

## Checks that the server answers for the bundle.
head! : Str => Try({}, Problem)
head! = |url| {
	without_scheme = url.drop_prefix("http://")
	(address, path) =
		match without_scheme.split_first("/") {
			Ok({ before, after }) => (before, "/${after}")
			Err(_) => (without_scheme, "/")
		}
	(host, port_text) =
		match address.split_last(":") {
			Ok({ before, after }) => (before, after)
			Err(_) => (address, "80")
		}
	port = U16.from_str(port_text) ? |_| Failed("Bad bundle URL: ${url}")
	timeouts = { connect_timeout: Duration.seconds(5), io_timeout: Duration.seconds(5) }
	connection = Tcp.connect!(host, port, timeouts) ? |err| Failed("Bundle server did not answer: ${Str.inspect(err)}")
	connection.write_bytes!("HEAD ${path} HTTP/1.0\r\nHost: ${address}\r\n\r\n".to_utf8()) ? |err| Failed("Bundle server did not answer: ${Str.inspect(err)}")
	status = connection.read_line!() ? |err| Failed("Bundle server did not answer: ${Str.inspect(err)}")
	if (status.contains(" 200 ")) Ok({}) else Err(Failed("Bundle server answered ${status.trim()} for ${url}"))
}

## Bundles the platform and returns the archive bundle.roc reports.
create_bundle! : Ctx => Try(Str, Problem)
create_bundle! = |ctx| {
	words = script(ctx, "bundle").append("--stub-missing-targets")
	output = Cmd.new(OsStr.from_str(words.first() ?? ""))
		.args(words.drop_first(1).map(OsStr.from_str))
		.cwd(Path.utf8(ctx.root))
		.stdout(Capture)
		.stderr(MergeWithStdout)
		.output_limit(NoLimit)
		.run!()
		? |err|
			match err {
				Interrupted => Interrupted
				CmdErr(cmd_err) => Failed("Bundling failed: ${cmd_err.to_str()}")
			}
	text = Str.from_utf8_lossy(output.stdout_bytes)
	Stdout.write!(text) ?? {}
	match output.status {
		Exited(0) => {}
		status => return Err(CommandFailed("bundle.roc", Process.exit_code(status)))
	}
	created = text.split_on("\n").keep_oks(created_archive).last() ? |_| Failed("Bundle creation did not report a created archive")
	# roc reports the archive relative to where it ran, and the bundle script
	# runs it from platform/.
	bundle = if (is_absolute(ctx.windows, created)) created else join(ctx, "platform/${created}")
	if (Path.utf8(bundle).is_file!() ?? False) Ok(bundle) else Err(Failed("Bundle creation did not produce an archive: ${bundle}"))
}

## `Created: NAME.tar.zst`
created_archive : Str -> Try(Str, [NotCreated])
created_archive = |line| {
	trimmed = line.trim_end()
	if trimmed.starts_with("Created:") {
		name = trimmed.drop_prefix("Created:")
		archive = name.trim_start()
		if (archive != name and archive.ends_with(".tar.zst") and archive != ".tar.zst") Ok(archive) else Err(NotCreated)
	} else {
		Err(NotCreated)
	}
}

# The spec

## An object of the spec. `load_spec!` checks every key of an app and of its
## cases against `app_keys` and `case_keys`, so the readers at the bottom
## take each value to have its key's type.
Obj : List((Str, JsonValue))

Spec : { defaults : List((Str, Bool)), apps : List(Obj) }

## `scratch` holds the binaries patched for Valgrind, and is empty without it.
Suite : { operations : List(Str), target : Str, artifact_dir : Str, valgrind : Bool, scratch : Str }

## The app folders the spec must cover.
app_dirs : List(Str)
app_dirs = ["examples", "tests", "tests/resource-lifetimes"]

load_spec! : Ctx => Try(Spec, Problem)
load_spec! = |ctx| {
	spec_path = join(ctx, "scripts/test_spec.json")
	data = JsonValue.parse(Files.read_text!(spec_path)?) ? |BadJson(why)| Failed("${spec_path}: ${why}")
	defaults_value = JsonValue.field(data, "stages") ?? Null
	defaults =
		match defaults_value {
			Object(fields) if fields.map(|(name, _)| name).sort_with(Files.compare) == stages.sort_with(Files.compare) =>
				fields.fold_try(
					[],
					|all, (name, flag)|
						match flag {
							Boolean(on) => Ok(all.append((name, on)))
							_ => Err(Failed("${spec_path}: all stage flags must be booleans"))
						},
				)?
			_ => return Err(Failed("${spec_path}: 'stages' must define ${Str.join_with(stages, ", ")}"))
		}
	apps =
		match JsonValue.field(data, "apps") ?? Null {
			Array(items) => items.fold_try(
				[],
				|all, item|
					match item {
						Object(fields) => Ok(all.append(fields))
						_ => Err(Failed("${spec_path}: 'apps' must be a list of objects"))
					},
			)?
			_ => return Err(Failed("${spec_path}: 'apps' must be a list of objects"))
		}
	for entry in apps {
		check_fields(app_path(entry), entry, app_keys)?
	}
	paths = apps.map(|entry| text_at(entry, "path") ?? "")
	if paths.any(Str.is_empty) or Files.unique(paths).len() != paths.len() {
		return Err(Failed("${spec_path}: every app needs a unique string path"))
	}
	discovered = app_dirs.fold_try!([], |all, dir| Ok(all.concat(roc_files!(ctx, dir)?)))?
	missing = discovered.drop_if(|path| paths.contains(path)).sort_with(Files.compare)
	extra = paths.drop_if(|path| discovered.contains(path)).sort_with(Files.compare)
	if !missing.is_empty() or !extra.is_empty() {
		return Err(Failed("Test spec mismatch; missing=${Str.inspect(missing)}, extra=${Str.inspect(extra)}"))
	}
	for entry in apps {
		names = cases_of(entry).map(|case| text_at(case, "name") ?? "")
		if names.any(Str.is_empty) or Files.unique(names).len() != names.len() {
			return Err(Failed("${app_path(entry)}: every run case needs a unique non-empty name"))
		}
		if stage_enabled(ctx, defaults, entry, "run") and names.is_empty() {
			return Err(Failed("${app_path(entry)}: run is enabled but cases is empty"))
		}
	}
	Ok({ defaults, apps })
}

# The keys of the spec

## What a key of the spec may hold.
Kind : [IsFlag, IsText, IsTexts, IsNumber, IsInteger, IsHex, IsSignal, IsHelper, IsPatterns, IsEnv, IsHexEnv, IsFixtures, IsCases, IsStages, IsAppPlatforms, IsCasePlatforms]

app_keys : List((Str, Kind))
app_keys = [
	("path", IsText),
	("reason", IsText),
	("enabled", IsFlag),
	("stages", IsStages),
	("platforms", IsAppPlatforms),
	("cases", IsCases),
]

case_keys : List((Str, Kind))
case_keys = [
	("name", IsText),
	("enabled", IsFlag),
	("platforms", IsCasePlatforms),
	("args", IsTexts),
	("cwd", IsText),
	("temp_cwd", IsFlag),
	("env", IsEnv),
	("unset_env", IsTexts),
	("non_utf8_env", IsHexEnv),
	("fixtures", IsFixtures),
	("stdin", IsText),
	("stdin_hex", IsHex),
	("timeout", IsNumber),
	("pty", IsFlag),
	("input_delay", IsNumber),
	("await_raw_mode", IsFlag),
	("await_output", IsText),
	("send_signal", IsSignal),
	("detach_terminal", IsFlag),
	("helper", IsHelper),
	("exit_code", IsInteger),
	("live_handles", IsInteger),
	("expect_crash", IsFlag),
	("valgrind", IsFlag),
	("contains", IsTexts),
	("stdout_contains", IsTexts),
	("stderr_contains", IsTexts),
	("regex", IsPatterns),
	("stdout_regex", IsPatterns),
	("stderr_regex", IsPatterns),
]

## The systems a `platforms` object may name.
systems : List(Str)
systems = ["linux", "darwin", "windows"]

## Refuses a key the schema does not know and a value of the wrong type.
check_fields : Str, Obj, List((Str, Kind)) -> Try({}, Problem)
check_fields = |place, fields, schema|
	fields.fold_try(
		{},
		|{}, (key, value)|
			match schema.find_first(|(name, _)| name == key) {
				Ok((_, kind)) => check_value("${place}: ${key}", kind, value)
				Err(_) => Err(Failed("${place}: unknown key ${Str.inspect(key)}"))
			},
	)

check_value : Str, Kind, JsonValue -> Try({}, Problem)
check_value = |place, kind, value| {
	wrong = |expected| Err(Failed("${place} must be ${expected}"))
	each = |items, check| items.fold_try({}, |{}, item| check(item))
	match (kind, value) {
		(IsFlag, Boolean(_)) => Ok({})
		(IsFlag, _) => wrong("true or false")
		(IsText, Text(_)) => Ok({})
		(IsText, _) => wrong("a string")
		(IsTexts, Array(items)) => each(items, |item| check_value(place, IsText, item))
		(IsTexts, _) => wrong("an array of strings")
		(IsNumber, Number(digits)) if Dec.from_str(digits).is_ok() => Ok({})
		(IsNumber, _) => wrong("a number")
		(IsInteger, Number(digits)) if I64.from_str(digits).is_ok() => Ok({})
		(IsInteger, _) => wrong("an integer")
		(IsHex, Text(digits)) if from_hex(digits).is_ok() => Ok({})
		(IsHex, _) => wrong("hex digits")
		(IsSignal, Text(name)) if signal_numbers.any(|(known, _, _)| known == name) => Ok({})
		(IsSignal, _) => wrong("one of ${Str.join_with(signal_numbers.map(|(known, _, _)| known), ", ")}")
		(IsHelper, Text("http")) => Ok({})
		(IsHelper, _) => wrong("\"http\"")
		(IsPatterns, Array(items)) =>
			each(
				items,
				|item|
					match item {
						Text(pattern) => check_pattern(place, pattern)
						_ => wrong("an array of patterns")
					},
			)
		(IsPatterns, _) => wrong("an array of patterns")
		(IsEnv, Object(pairs)) =>
			each(
				pairs,
				|(_, item)|
					match item {
						Text(_) | Number(_) => Ok({})
						_ => wrong("an object of strings")
					},
			)
		(IsEnv, _) => wrong("an object of strings")
		(IsHexEnv, Object(pairs)) => each(pairs, |(_, item)| check_value(place, IsHex, item))
		(IsHexEnv, _) => wrong("an object of hex digits")
		(IsFixtures, Array(items)) =>
			each(
				items,
				|item|
					match item {
						Object(fields) if text_at(fields, "source").is_ok() and text_at(fields, "target").is_ok() => check_fields(place, fields, [("source", IsText), ("target", IsText)])
						_ => wrong("an array of objects with a source and a target")
					},
			)
		(IsFixtures, _) => wrong("an array of objects with a source and a target")
		(IsCases, Array(items)) =>
			each(
				items,
				|item|
					match item {
						Object(fields) => check_fields("${place} ${text_at(fields, "name") ?? "?"}", fields, case_keys)
						_ => wrong("an array of objects")
					},
			)
		(IsCases, _) => wrong("an array of objects")
		(IsStages, Object(fields)) => check_fields(place, fields, stages.map(|stage| (stage, IsFlag)))
		(IsStages, _) => wrong("an object")
		(IsAppPlatforms, Object(pairs)) => check_platforms(place, pairs, stages.map(|stage| (stage, IsFlag)).append(("enabled", IsFlag)))
		(IsCasePlatforms, Object(pairs)) => check_platforms(place, pairs, [("enabled", IsFlag)])
		(IsAppPlatforms, _) | (IsCasePlatforms, _) => wrong("an object of ${Str.join_with(systems, ", ")}")
	}
}

## A `platforms` object: the overrides of each system.
check_platforms : Str, Obj, List((Str, Kind)) -> Try({}, Problem)
check_platforms = |place, pairs, keys|
	pairs.fold_try(
		{},
		|{}, (system, item)|
			match item {
				Object(fields) if systems.contains(system) => check_fields("${place}.${system}", fields, keys)
				_ => Err(Failed("${place} must be an object of ${Str.join_with(systems, ", ")}"))
			},
	)

## A pattern roc-regex compiles, without an unescaped `_`, `&` or `~`.
## roc-regex reads `_` as any byte and `&` and `~` as operators, so a pattern
## that means them literally writes `\_`, `\&` and `\~`.
check_pattern : Str, Str -> Try({}, Problem)
check_pattern = |place, pattern| {
	match unescaped_operator(pattern.to_utf8()) {
		Ok(byte) => Err(Failed("${place}: regex ${Str.inspect(pattern)} has an unescaped ${Str.from_utf8_lossy([byte])}, which roc-regex does not read as itself. Write \\${Str.from_utf8_lossy([byte])}"))
		Err(NoOperator) => compile_regex(pattern).map_ok(|_| {}).map_err(|BadRegex(why)| Failed("${place}: bad regex ${Str.inspect(pattern)}: ${why}"))
	}
}

## The first `_`, `&` or `~` that no `\` escapes.
unescaped_operator : List(U8) -> Try(U8, [NoOperator])
unescaped_operator = |bytes|
	match bytes {
		['\\', _, .. as rest] => unescaped_operator(rest)
		[byte, .. as rest] => if (byte == '_' or byte == '&' or byte == '~') Ok(byte) else unescaped_operator(rest)
		[] => Err(NoOperator)
	}

## The `.roc` files directly in a folder of the repository, as paths from
## its root written with `/`.
roc_files! : Ctx, Str => Try(List(Str), Problem)
roc_files! = |ctx, dir| Ok(Files.files_in!(join(ctx, dir), ".roc")?.map(|file| "${dir}/${Files.base_name(file)}"))

app_path : Obj -> Str
app_path = |entry| text_at(entry, "path") ?? "?"

## Whether a stage runs for an app on this system: the spec's default, the
## app's `stages` and then its `platforms` entry for this system decide.
stage_enabled : Ctx, List((Str, Bool)), Obj, Str -> Bool
stage_enabled = |ctx, defaults, entry, stage| {
	on_system = object_at(object_at(entry, "platforms"), ctx.system)
	default = defaults.find_first(|(name, _)| name == stage).map_ok(|(_, on)| on) ?? False
	flag_at(entry, "enabled", True) and flag_at(on_system, "enabled", True) and flag_at(on_system, stage, flag_at(object_at(entry, "stages"), stage, default))
}

## The apps the build stage builds on this system.
built_apps : Ctx, Spec -> List(Str)
built_apps = |ctx, spec| spec.apps.keep_if(|entry| stage_enabled(ctx, spec.defaults, entry, "build")).map(app_path)

cases_of : Obj -> List(Obj)
cases_of = |entry| JsonValue.items_of(get(entry, "cases") ?? Null).map(JsonValue.fields_of)

case_enabled : Ctx, Obj -> Bool
case_enabled = |ctx, case| flag_at(case, "enabled", True) and flag_at(object_at(object_at(case, "platforms"), ctx.system), "enabled", True)

# Stages

## The binary each app was built into, by its path in the spec.
Binaries : List((Str, Str))

run_stage! : Ctx, Str, Spec, Binaries, Suite => Try(Binaries, Problem)
run_stage! = |ctx, stage, spec, binaries, suite| {
	Stdout.line!("\n=== ${stage.with_ascii_uppercased()} ===") ?? {}
	spec.apps.fold_try!(
		binaries,
		|built, app_fields| {
			path = app_path(app_fields)
			source = join(ctx, path)
			if !stage_enabled(ctx, spec.defaults, app_fields, stage) {
				reason =
					match text_at(app_fields, "reason") {
						Ok(text) if !text.is_empty() => " (${text})"
						_ => ""
					}
				Stdout.line!("SKIP ${stage}: ${path}${reason}") ?? {}
				return Ok(built)
			}
			match stage {
				"fmt" => {
					Process.call!([ctx.roc, "fmt", "--check", source], ctx.root)?
					Ok(built)
				}
				"check" => {
					Process.call!([ctx.roc, "check", source].concat(roc_extra_args(ctx)), ctx.root)?
					Ok(built)
				}
				"test" => {
					Process.call!([ctx.roc, "test", source].concat(roc_extra_args(ctx)), ctx.root)?
					Ok(built)
				}
				"build" => {
					binary = artifact_binary(ctx, suite.artifact_dir, suite.target, path)
					Path.utf8(native_join(ctx.windows, suite.artifact_dir, suite.target)).create_all!() ? |err| Failed("could not create the artifact folder: ${Str.inspect(err)}")
					Process.call!([ctx.roc, "build", source, "--target=${suite.target}", "--output=${binary}"].concat(roc_extra_args(ctx)), ctx.root)?
					Ok(built.append((path, binary)))
				}
				_ => {
					binary = built.find_first(|(built_path, _)| built_path == path).map_ok(|(_, file)| file) ? |_| Failed("${path}: run is enabled but build is disabled")
					for case in cases_of(app_fields) {
						name = text_at(case, "name") ?? "?"
						if suite.valgrind and !flag_at(case, "valgrind", True) {
							Stdout.line!("SKIP run case under Valgrind: ${path} [${name}]") ?? {}
						} else if case_enabled(ctx, case) {
							run_binary!(ctx, path, binary, case, suite)?
						} else {
							Stdout.line!("SKIP run case: ${path} [${name}]") ?? {}
						}
					}
					Ok(built)
				}
			}
		},
	)
}

## Where an app's binary goes: apps in nested folders are prefixed to stay
## unique.
artifact_binary : Ctx, Str, Str, Str -> Str
artifact_binary = |ctx, artifact_dir, target, path| native_join(ctx.windows, artifact_dir, artifact_relative(target, path))

artifact_relative : Str, Str -> Str
artifact_relative = |target, path| {
	suffix = if (target == "x64win") ".exe" else ""
	"${target}/${binary_stem(path)}${suffix}"
}

binary_stem : Str -> Str
binary_stem = |path| Str.join_with(path.drop_suffix(".roc").split_on("/").drop_first(1), "-")

run_suite! : Ctx, Str, Suite => Try({}, Problem)
run_suite! = |ctx, bundle_url, suite| {
	spec = load_spec!(ctx)?
	paths = spec.apps.map(app_path)
	backups = paths.fold_try!([], |all, path| Ok(all.append((path, Files.read_bytes!(join(ctx, path))?))))?
	# The hash covers the apps the build stage builds, as load_artifact_binaries!
	# checks it.
	built = built_apps(ctx, spec)
	original_sources_sha256 = sources_hash(backups.keep_if(|(path, _)| built.contains(path)))
	result = suite_steps!(ctx, bundle_url, suite, spec, original_sources_sha256)
	# Signals caught while the suite ran are answered by stopping here.
	_ = Signal.poll!()
	restored = backups.fold_try!({}, |{}, (path, bytes)| Path.utf8(join(ctx, path)).write_bytes!(bytes).map_err(|err| Failed("could not restore ${path}: ${Str.inspect(err)}")))
	cleanup_test_files!(ctx)
	result?
	restored
}

suite_steps! : Ctx, Str, Suite, Spec, Str => Try({}, Problem)
suite_steps! = |ctx, bundle_url, suite, spec, original_sources_sha256| {
	_ = AppPlatformUrls.update_apps!(app_dirs.map(|dir| join(ctx, dir)), bundle_url) ? |AppUrls(message)| Failed(message)
	if suite.operations.contains("run") and needs_http_server(ctx, spec) {
		Process.call!(["cargo", "build", "--locked", "--release"], join(ctx, "ci/rust_http_server"))?
	}
	if suite.operations.contains("validate") {
		Stdout.line!("\n=== RUST TEST ===") ?? {}
		Process.call!(["cargo", "test", "--locked", "--lib"], ctx.root)?
		Stdout.line!("\n=== PLATFORM TEST ===") ?? {}
		Process.call!([ctx.roc, "test", join(ctx, "platform/main.roc")].concat(roc_extra_args(ctx)), ctx.root)?
		for stage in ["fmt", "check", "test"] {
			_ = run_stage!(ctx, stage, spec, [], suite)?
		}
	}
	built =
		if suite.operations.contains("build") {
			binaries = run_stage!(ctx, "build", spec, [], suite)?
			write_manifest!(ctx, suite, binaries, original_sources_sha256)?
			if suite.target == Targets.native!()? {
				run_from_source!(ctx)?
			}
			binaries
		} else {
			[]
		}
	if suite.operations.contains("run") {
		binaries = if (built.is_empty()) load_artifact_binaries!(ctx, suite.target, suite.artifact_dir, spec)? else built
		_ = run_stage!(ctx, "run", spec, binaries, suite)?
	}
	Ok({})
}

## The app `run_from_source!` runs, and a line it prints.
source_run_app : Str
source_run_app = "examples/hello-world.roc"

source_run_output : Str
source_run_output = "Hello, World!"

## How `roc` runs an app from its source with a backend. The cache is off, as
## it would answer with an executable linked earlier.
source_run_words : Ctx, Str, Str -> List(Str)
source_run_words = |ctx, opt, source| [ctx.roc, "--opt=${opt}", "--no-cache", "--max-transitive-mb=256", source]

## Runs an app from its source, as `roc app.roc` does, with the backends that
## link a runtime of roc's own beside the host: dev and interpreter.
## `roc build` links neither runtime, so only this finds a symbol one of them
## imports that the platform's macOS link stubs do not list.
run_from_source! : Ctx => Try({}, Problem)
run_from_source! = |ctx| {
	Stdout.line!("\n=== RUN FROM SOURCE ===") ?? {}
	for opt in ["dev", "interpreter"] {
		words = source_run_words(ctx, opt, join(ctx, source_run_app))
		shown = Str.join_with(words, " ")
		Stdout.line!("+ ${shown}") ?? {}
		output = Cmd.new(OsStr.from_str(ctx.roc))
			.args(words.drop_first(1).map(OsStr.from_str))
			.cwd(Path.utf8(ctx.root))
			.stdout(Capture)
			.stderr(MergeWithStdout)
			.output_limit(NoLimit)
			.run!()
			? |err|
				match err {
					Interrupted => Interrupted
					CmdErr(cmd_err) => Failed("${shown}: ${cmd_err.to_str()}")
				}
		text = Str.from_utf8_lossy(output.stdout_bytes)
		Stdout.write!(text) ?? {}
		match output.status {
			Exited(0) => {}
			status => return Err(CommandFailed(shown, Process.exit_code(status)))
		}
		if !text.contains(source_run_output) {
			return Err(Failed("${shown}: did not print \"${source_run_output}\""))
		}
	}
	Ok({})
}

needs_http_server : Ctx, Spec -> Bool
needs_http_server = |ctx, spec|
	spec.apps.any(|entry| stage_enabled(ctx, spec.defaults, entry, "run") and cases_of(entry).any(|case| case_enabled(ctx, case) and text_at(case, "helper") == Ok("http")))

run_artifact_cases! : Ctx, Str, Str, Bool => Try({}, Problem)
run_artifact_cases! = |ctx, target, artifact_dir, valgrind| {
	spec = load_spec!(ctx)?
	binaries = load_artifact_binaries!(ctx, target, artifact_dir, spec)?
	if needs_http_server(ctx, spec) {
		Process.call!(["cargo", "build", "--locked", "--release"], join(ctx, "ci/rust_http_server"))?
	}
	scratch = valgrind_scratch!(valgrind)?
	suite = { operations: ["run"], target, artifact_dir, valgrind, scratch }
	result = run_stage!(ctx, "run", spec, binaries, suite)
	# Signals caught while the cases ran are answered by stopping here.
	_ = Signal.poll!()
	remove_scratch!(scratch)
	cleanup_test_files!(ctx)
	_ = result?
	Ok({})
}

## Removes what the apps leave in their folders.
cleanup_test_files! : Ctx => {}
cleanup_test_files! = |ctx|
	for dir in app_dirs {
		entries = Path.utf8(join(ctx, dir)).list!() ?? []
		for entry in entries {
			name = Files.split_path(Path.display(entry)).1
			if name.ends_with(".e2e.db") or name.ends_with(".bak") {
				entry.delete!() ?? {}
			}
		}
	}

# Artifacts

spec_hash! : Ctx => Try(Str, Problem)
spec_hash! = |ctx| Ok(Crypto.SHA256.hash(Files.read_bytes!(join(ctx, "scripts/test_spec.json"))?).to_hex())

## A hash of the app sources by their paths, in path order.
sources_hash : List((Str, List(U8))) -> Str
sources_hash = |sources| {
	bytes = sources
		.sort_with(|(a, _), (b, _)| Files.compare(a, b))
		.fold([], |all, (name, contents)| all.concat(name.to_utf8()).append(0).concat(contents).append(0))
	Crypto.SHA256.hash(bytes).to_hex()
}

write_manifest! : Ctx, Suite, Binaries, Str => Try({}, Problem)
write_manifest! = |ctx, suite, binaries, sources_sha256| {
	spec_sha256 = spec_hash!(ctx)?
	entries = binaries
		.sort_with(|(a, _), (b, _)| Files.compare(a, b))
		.map(|(source, _)| (source, Text(artifact_relative(suite.target, source))))
	manifest : JsonValue
	manifest = Object([("target", Text(suite.target)), ("spec_sha256", Text(spec_sha256)), ("sources_sha256", Text(sources_sha256)), ("binaries", Object(entries))])
	path = native_join(ctx.windows, suite.artifact_dir, "${suite.target}/manifest.json")
	Path.utf8(path).write_utf8!("${JsonValue.render(manifest)}\n").map_err(|err| Failed("could not write ${path}: ${Str.inspect(err)}"))
}

load_artifact_binaries! : Ctx, Str, Str, Spec => Try(Binaries, Problem)
load_artifact_binaries! = |ctx, target, artifact_dir, spec| {
	manifest_path = native_join(ctx.windows, artifact_dir, "${target}/manifest.json")
	if !(Path.utf8(manifest_path).is_file!() ?? False) {
		return Err(Failed("Missing artifact manifest: ${manifest_path}"))
	}
	parsed : Try({ target : Str, spec_sha256 : Str, sources_sha256 : Str, binaries : Dict(Str, Str) }, _)
	parsed = Json.parse(Files.read_text!(manifest_path)?)
	manifest = parsed ? |err| Failed("${manifest_path} is not an artifact manifest: ${Str.inspect(err)}")
	if manifest.target != target {
		return Err(Failed("${manifest_path}: target does not match ${target}"))
	}
	if manifest.spec_sha256 != spec_hash!(ctx)? {
		return Err(Failed("${manifest_path}: artifacts were built from a different test spec"))
	}
	entries = manifest.binaries.to_list()
	expected = built_apps(ctx, spec)
	sources = expected.fold_try!([], |all, path| Ok(all.append((path, Files.read_bytes!(join(ctx, path))?))))?
	if manifest.sources_sha256 != sources_hash(sources) {
		return Err(Failed("${manifest_path}: artifacts were built from different example sources"))
	}
	names = entries.map(|(name, _)| name)
	missing = expected.drop_if(|path| names.contains(path)).sort_with(Files.compare)
	extra = names.drop_if(|path| expected.contains(path)).sort_with(Files.compare)
	if !missing.is_empty() or !extra.is_empty() {
		return Err(Failed("${manifest_path}: binary mismatch; missing=${Str.inspect(missing)}, extra=${Str.inspect(extra)}"))
	}
	binaries = entries.map(|(source, relative)| (source, native_join(ctx.windows, artifact_dir, relative)))
	absent = binaries.fold_try!([], |all, (source, binary)| Ok(if (Path.utf8(binary).is_file!() ?? False) all else all.append(source)))?
	if !absent.is_empty() {
		return Err(Failed("${manifest_path}: missing binary files for ${Str.inspect(absent.sort_with(Files.compare))}"))
	}
	if !ctx.windows and !binaries.is_empty() {
		_ = Process.capture!(["chmod", "a+x"].concat(binaries.map(|(_, binary)| binary)))?
	}
	Ok(binaries)
}

# Run cases

## What a run of an app printed and how it ended.
Ran : { exit_code : I32, stdout : Str, stderr : Str }

run_binary! : Ctx, Str, Str, Obj, Suite => Try({}, Problem)
run_binary! = |ctx, path, built_binary, case, suite| {
	valgrind = suite.valgrind
	source = join(ctx, path)
	name = text_at(case, "name") ?? "?"
	label = "${source} [${name}]"
	Stdout.line!("\n--- ${path} [${name}] ---") ?? {}
	binary = if (valgrind) valgrind_binary!(ctx, suite.scratch, built_binary)? else built_binary
	expanded = texts_at(case, "args").fold_try(
		[],
		|all, arg| Ok(all.append(expand(ctx, arg, source)?)),
	)?
	words = (if (valgrind) valgrind_args(ctx) else []).append(binary).concat(expanded)
	temp_cwd =
		if flag_at(case, "temp_cwd", False) {
			match Env.create_temp_dir_with_prefix!("basic-cli-case-") {
				Ok(dir) => Ok(dir)
				Err(err) => return Err(Failed("could not create a folder: ${Str.inspect(err)}"))
			}
		} else {
			Err(NoTemp)
		}
	cwd =
		match temp_cwd {
			Ok(dir) => Path.display(dir)
			Err(_) => expand(ctx, text_at(case, "cwd") ?? "{root}", source)?
		}
	stdin =
		match text_at(case, "stdin_hex") {
			Ok(hex) => from_hex(hex) ?? []
			Err(_) => (text_at(case, "stdin") ?? "").to_utf8()
		}
	timeout = (Dec.from_str(number_at(case, "timeout") ?? "7") ?? 7) * (if (valgrind) 4 else 1)
	send_signal = text_at(case, "send_signal")
	pty = flag_at(case, "pty", False)
	if send_signal.is_ok() and !pty {
		return Err(Failed("${label}: send_signal needs a PTY case"))
	}
	fixtures = copy_fixtures!(ctx, case)?
	outcome = with_helper_server!(
		ctx,
		text_at(case, "helper"),
		|| {
			setup = environment!(ctx, case, source, pty)?
			if pty {
				terminal!(ctx, setup, words, cwd, stdin, timeout, case, send_signal)
			} else {
				pipe!(ctx, setup, words, cwd, stdin, timeout, flag_at(case, "detach_terminal", False))
			}
		},
	)
	for target in fixtures {
		Path.utf8(target).delete!() ?? {}
	}
	match temp_cwd {
		Ok(dir) => dir.delete_all!() ?? {}
		Err(_) => {}
	}
	ran = outcome?
	if !ran.stdout.is_empty() {
		Stdout.write!(if (ran.stdout.ends_with("\n")) ran.stdout else "${ran.stdout}\n") ?? {}
	}
	if !ran.stderr.is_empty() {
		Stderr.write!(if (ran.stderr.ends_with("\n")) ran.stderr else "${ran.stderr}\n") ?? {}
	}
	expected_exit =
		match number_at(case, "exit_code") {
			Ok(digits) => (I64.from_str(digits) ?? 0).to_i32_wrap()
			Err(Missing) =>
				match send_signal {
					Ok(signal) => signal_exit_code(ctx, signal) ? |_| Failed("${label}: unknown signal ${signal}")
					Err(_) => 0
				}
		}
	if ran.exit_code != expected_exit {
		return Err(Failed("${label}: exited with ${ran.exit_code.to_str()}, expected ${expected_exit.to_str()}"))
	}
	verify_output(label, ran, case, pty)
}

## The signals tools/test-helper can send, with their numbers on Linux and on
## macOS.
signal_numbers : List((Str, I32, I32))
signal_numbers = [
	("SIGHUP", 1, 1),
	("SIGINT", 2, 2),
	("SIGQUIT", 3, 3),
	("SIGKILL", 9, 9),
	("SIGUSR1", 10, 30),
	("SIGUSR2", 12, 31),
	("SIGTERM", 15, 15),
	("SIGWINCH", 28, 28),
]

## The exit code of a program a signal stopped: minus the signal. Windows
## has no signals, and the console runner sends Ctrl+Break in their place.
signal_exit_code : Ctx, Str -> Try(I32, [UnknownSignal])
signal_exit_code = |ctx, name| {
	(_, linux, macos) = signal_numbers.find_first(|(known, _, _)| known == name) ? |_| UnknownSignal
	if ctx.windows {
		# STATUS_CONTROL_C_EXIT
		Ok((0xC000013A.U32).to_i32_wrap())
	} else if ctx.system == "darwin" {
		Ok(0 - macos)
	} else {
		Ok(0 - linux)
	}
}

valgrind_args : Ctx -> List(Str)
valgrind_args = |ctx| [
	"valgrind",
	"--error-exitcode=99",
	"--leak-check=full",
	"--show-leak-kinds=all",
	"--errors-for-leak-kinds=all",
	"--track-origins=yes",
	"--realloc-zero-bytes-frees=no",
	"--suppressions=${join(ctx, "ci/valgrind.supp")}",
]

copy_fixtures! : Ctx, Obj => Try(List(Str), Problem)
copy_fixtures! = |ctx, case|
	JsonValue.items_of(get(case, "fixtures") ?? Null).fold_try!(
		[],
		|copied, item| {
			fixture = JsonValue.fields_of(item)
			from = join(ctx, text_at(fixture, "source") ?? "")
			target = join(ctx, text_at(fixture, "target") ?? "")
			Path.utf8(from).copy!(Path.utf8(target)) ? |err| Failed("could not copy a fixture: ${Str.inspect(err)}")
			Ok(copied.append(target))
		},
	)

## The environment a case runs in: this process's, or a copy of it without
## some variables, and the variables the case sets.
EnvSetup : { clear : Bool, pairs : List((OsStr, OsStr)) }

## The command's environment: this process's, without `unset_env`, with
## `env`, the live-handle switch and `non_utf8_env`.
environment! : Ctx, Obj, Str, Bool => Try(EnvSetup, Problem)
environment! = |ctx, case, source, pty| {
	unset = texts_at(case, "unset_env")
	base =
		if unset.is_empty() {
			{ clear: False, pairs: [] }
		} else {
			{ clear: True, pairs: Env.dict!().drop_if(|(name, _)| unset.contains(OsStr.display(name))) }
		}
	assigned = object_at(case, "env").fold_try(
		[],
		|all, (name, value)| {
			expanded =
				match value {
					Text(template) => expand(ctx, template, source)?
					other => JsonValue.render(other)
				}
			Ok(all.append((OsStr.from_str(name), OsStr.from_str(expanded))))
		},
	)?
	handles = if (get(case, "live_handles").is_ok()) [(OsStr.from_str(live_handles_env), OsStr.from_str("1"))] else []
	non_utf8 = if (ctx.windows) [] else object_at(case, "non_utf8_env")
	if pty and !non_utf8.is_empty() {
		return Err(Failed("${source}: PTY tests require a text environment"))
	}
	raw = non_utf8.map(|(name, value)| (OsStr.from_str(name), OsStr.unix_bytes(from_hex(JsonValue.text_of(value) ?? "") ?? [])))
	Ok({ clear: base.clear, pairs: base.pairs.concat(assigned).concat(handles).concat(raw) })
}

## A command for a program and its arguments in an environment.
command_for : EnvSetup, List(Str) -> Cmd.Command
command_for = |setup, words| {
	cmd = Cmd.new(OsStr.from_str(words.first() ?? "")).args(words.drop_first(1).map(OsStr.from_str))
	cleared = if (setup.clear) cmd.clear_envs() else cmd
	cleared.envs(setup.pairs)
}

## Runs a program with piped standard streams.
pipe! : Ctx, EnvSetup, List(Str), Str, List(U8), Dec, Bool => Try(Ran, Problem)
pipe! = |ctx, env, words, cwd, stdin, timeout, detach| {
	# A process can reach its terminal without using the standard streams, so
	# a detached one is left with no controlling terminal or console at all.
	run_words = if (detach) [ctx.helper, "detached", "--"].concat(words) else words
	cmd = command_for(env, run_words)
		.cwd(Path.utf8(cwd))
		.stdin(Bytes(stdin))
		.stdout(Capture)
		.stderr(Capture)
		.output_limit(NoLimit)
		.timeout(seconds(timeout))
		# On Windows the helper starts the program as its child and waits, so a
		# timeout stops the whole tree, or the program would keep the pipes. On
		# Unix the helper becomes the program after setsid, which a process
		# group leader cannot call, so the tree is not managed there.
		.manage_tree(detach and ctx.windows)
	match cmd.run!() {
		Ok(output) => Ok({ exit_code: status_number(output.status), stdout: output.stdout_utf8_lossy(), stderr: output.stderr_utf8_lossy() })
		Err(CmdErr(TimedOut(_))) => Err(Failed("Timed out after ${timeout.to_str()}s: ${Str.join_with(words, " ")}"))
		Err(CmdErr(err)) => Err(Failed("${err.to_str()}: ${Str.join_with(words, " ")}"))
		Err(Interrupted) => Err(Interrupted)
	}
}

## Runs a program on a terminal of its own, through the helper: a
## pseudo-terminal on Unix, a hidden console on Windows.
terminal! : Ctx, EnvSetup, List(Str), Str, List(U8), Dec, Obj, Try(Str, _) => Try(Ran, Problem)
terminal! = |ctx, env, words, cwd, stdin, timeout, case, send_signal| {
	input_delay = Dec.from_str(number_at(case, "input_delay") ?? "0.08") ?? 0.08
	options = ["terminal", "--timeout", timeout.to_str(), "--input-delay", input_delay.to_str(), "--stdin-hex", to_hex(stdin)]
		.concat(if (flag_at(case, "await_raw_mode", False)) ["--await-raw-mode"] else [])
		.concat(
			match text_at(case, "await_output") {
				Ok(text) => ["--await-output", text]
				Err(_) => []
			},
		)
		.concat(
			match send_signal {
				Ok(name) => ["--send-signal", name]
				Err(_) => []
			},
		)
	# The program runs as the helper's child, so a timeout stops the whole
	# process tree.
	cmd = command_for(env, [ctx.helper].concat(options).append("--").concat(words))
		.cwd(Path.utf8(cwd))
		.stdin(Null)
		.stdout(Capture)
		.stderr(Capture)
		.output_limit(NoLimit)
		.timeout(seconds(timeout + 30))
		.manage_tree(Bool.True)
	shown = Str.join_with(words, " ")
	output =
		match cmd.run!() {
			Ok(finished) => finished
			Err(CmdErr(err)) => return Err(Failed("Terminal runner failed: ${shown}\n${err.to_str()}"))
			Err(Interrupted) => return Err(Interrupted)
		}
	report = output.stdout_utf8_lossy()
	if output.status != Exited(0) or report.trim().is_empty() {
		return Err(Failed("Terminal runner failed: ${shown}\n${output.stderr_utf8_lossy()}"))
	}
	parsed : Try({ exit_code : Try(I64, [Null]), output : Try(Str, [Null]), error : Try(Str, [Null]) }, _)
	parsed = Json.parse(report.trim())
	match parsed {
		Ok({ error: Ok(error), .. }) => Err(Failed("${error}: ${shown}"))
		Ok({ exit_code: Ok(code), output: Ok(text), .. }) => Ok({ exit_code: code.to_i32_wrap(), stdout: text, stderr: "" })
		_ => Err(Failed("Terminal runner printed no result: ${shown}\n${report}"))
	}
}

seconds : Dec -> Duration
seconds = |value| Duration.millis((value * 1000).round().to_u64_try() ?? 0)

## Starts the helper server a case names, runs `body!`, and stops it.
with_helper_server! : Ctx, Try(Str, _), (() => Try(Ran, Problem)) => Try(Ran, Problem)
with_helper_server! = |ctx, name, body!|
	match name {
		Err(_) => body!()
		Ok("http") => {
			exe = if (ctx.windows) ".exe" else ""
			server_binary = join(ctx, "ci/rust_http_server/target/release/rust_http_server${exe}")
			server = Cmd.new(OsStr.from_str(server_binary))
				.cwd(Path.utf8(ctx.root))
				.stdin(Null)
				.stdout(Null)
				.stderr(Null)
				.spawn_leashed!() ? |err| Failed("could not start ${server_binary}: ${Str.inspect(err)}")
			result =
				match wait_for_port!(server, 9000, Monotonic.now!()) {
					Ok({}) => body!()
					Err(problem) => Err(problem)
				}
			server.kill!() ?? {}
			_ = server.wait!()
			result
		}
		Ok(other) => Err(Failed("Unknown helper server: ${other}"))
	}

wait_for_port! : Cmd.Child, U16, Monotonic => Try({}, Problem)
wait_for_port! = |server, port, started| {
	if started.elapsed!() >= Duration.seconds(5) {
		return Err(Failed("Helper server did not listen on port ${port.to_str()}"))
	}
	match server.poll!() {
		Ok(Running) => {}
		_ => return Err(Failed("Helper server on port ${port.to_str()} exited early"))
	}
	match Tcp.connect!("127.0.0.1", port, { connect_timeout: Duration.millis(100), io_timeout: Duration.millis(100) }) {
		Ok(_) => Ok({})
		Err(Interrupted) => Err(Interrupted)
		Err(_) => {
			Sleep.millis!(50) ? |Interrupted| Interrupted
			wait_for_port!(server, port, started)
		}
	}
}

## `{root}`, `{source}`, `{source_dir}` and `{helper}` in a value, with `{{`
## and `}}` for braces.
expand : Ctx, Str, Str -> Try(Str, Problem)
expand = |ctx, value, source| {
	(source_dir, _) = Files.split_path(source)
	var $out = []
	var $rest = value.to_utf8()
	while !$rest.is_empty() {
		match $rest {
			['{', '{', .. as more] => {
				$out = $out.append('{')
				$rest = more
			}
			['}', '}', .. as more] => {
				$out = $out.append('}')
				$rest = more
			}
			['{', .. as more] => {
				(name, rest_after) =
					match more.split_first('}') {
						Ok({ before, after }) => (Str.from_utf8_lossy(before), after)
						Err(_) => return Err(Failed("${source}: unclosed placeholder in ${value}"))
					}
				replacement =
					match name {
						"root" => ctx.root
						"source" => source
						"source_dir" => source_dir
						"helper" => ctx.helper
						_ => return Err(Failed("${source}: unknown placeholder {${name}} in ${value}"))
					}
				$out = $out.concat(replacement.to_utf8())
				$rest = rest_after
			}
			[byte, .. as more] => {
				$out = $out.append(byte)
				$rest = more
			}
			[] => {}
		}
	}
	Ok(Str.from_utf8_lossy($out))
}

# Checking the output

verify_output : Str, Ran, Obj, Bool -> Try({}, Problem)
verify_output = |label, ran, case, pty| {
	combined = if (pty) ran.stdout else "${ran.stdout}${ran.stderr}"
	expect_crash = flag_at(case, "expect_crash", False)
	verify_text(label, "combined output", combined, case, "contains", "regex", expect_crash)?
	if pty and ["stdout_contains", "stdout_regex", "stderr_contains", "stderr_regex"].any(|key| get(case, key).is_ok()) {
		return Err(Failed("${label}: PTY cases cannot assert separate streams"))
	}
	match number_at(case, "live_handles") {
		Ok(digits) => {
			expected = U64.from_str(digits) ? |_| Failed("${label}: live_handles must not be negative")
			# The host writes the report to stderr, which a PTY merges into
			# stdout. Child processes inherit the variable and may report too,
			# so every report must match: one child's zero must not hide the
			# app's leak.
			reports = live_handle_reports(if (pty) ran.stdout else ran.stderr)
			if reports.is_empty() or reports.any(|count| count != expected) {
				shown = if (reports.is_empty()) "none" else Str.inspect(reports.map(|count| count.to_str()))
				return Err(Failed("${label}: expected every live-handle report to be ${expected.to_str()}, got ${shown}"))
			}
		}
		Err(Missing) => {}
	}
	if !pty {
		verify_text(label, "stdout", ran.stdout, case, "stdout_contains", "stdout_regex", expect_crash)?
		verify_text(label, "stderr", ran.stderr, case, "stderr_contains", "stderr_regex", expect_crash)?
	}
	Ok({})
}

verify_text : Str, Str, Str, Obj, Str, Str, Bool -> Try({}, Problem)
verify_text = |label, stream, output, case, contains_key, regex_key, expect_crash| {
	normalized = output.replace_each("\r\n", "\n").replace_each("\r", "\n")
	if normalized.contains("[ROC CRASHED]") and !expect_crash {
		return Err(Failed("${label}: runtime crash\n${normalized}"))
	}
	for expected in texts_at(case, contains_key) {
		if !normalized.contains(expected) {
			return Err(Failed("${label}: missing ${stream} output ${Str.inspect(expected)}\n--- ${stream} ---\n${normalized}"))
		}
	}
	for pattern in texts_at(case, regex_key) {
		regex = compile_regex(pattern) ? |BadRegex(why)| Failed("${label}: bad regex ${Str.inspect(pattern)}: ${why}")
		if !Regex.is_match_str(regex, normalized) {
			return Err(Failed("${label}: ${stream} did not match ${Str.inspect(pattern)}\n--- ${stream} ---\n${normalized}"))
		}
	}
	Ok({})
}

## A pattern of the spec, as roc-regex reads it. In it `_` is any byte, so an
## underscore is written `\_`, and `&` and `~` are operators.
compile_regex : Str -> Try(Regex.Pattern, [BadRegex(Str)])
compile_regex = |pattern| Regex.compile(pattern).map_err(|err| BadRegex(Regex.err_str(err)))

## The counts of every `live handles: N` line.
live_handle_reports : Str -> List(U64)
live_handle_reports = |text|
	text.split_on("\n").keep_oks(
		|line| {
			count = line.drop_suffix("\r")
			if count.starts_with("live handles: ") {
				digits = count.drop_prefix("live handles: ")
				if (!digits.is_empty() and digits.to_utf8().all(|byte| byte >= '0' and byte <= '9')) U64.from_str(digits) else Err(BadNumStr)
			} else {
				Err(BadNumStr)
			}
		},
	)

# Valgrind

## A folder for the binaries patched for Valgrind, or nothing without it.
valgrind_scratch! : Bool => Try(Str, Problem)
valgrind_scratch! = |valgrind|
	if valgrind {
		match Env.create_temp_dir_with_prefix!("basic-cli-valgrind-") {
			Ok(dir) => Ok(Path.display(dir))
			Err(err) => Err(Failed("could not create a folder for Valgrind: ${Str.inspect(err)}"))
		}
	} else {
		Ok("")
	}

remove_scratch! : Str => {}
remove_scratch! = |scratch|
	if scratch.is_empty() {
		{}
	} else {
		Path.utf8(scratch).delete_all!() ?? {}
	}

## A binary Valgrind can read symbols from: `binary`, or a patched copy of it
## in the run's scratch folder, made once.
valgrind_binary! : Ctx, Str, Str => Try(Str, Problem)
valgrind_binary! = |ctx, scratch, binary| {
	digest = Str.from_utf8_lossy(Crypto.SHA256.hash(binary.to_utf8()).to_hex().to_utf8().take_first(16))
	dir = native_join(ctx.windows, scratch, digest)
	copy = native_join(ctx.windows, dir, Files.split_path(binary).1)
	if Path.utf8(copy).is_file!() ?? False {
		return Ok(copy)
	}
	image = Files.read_bytes!(binary)?
	patches = merged_rw_segment_patches(image)
	if patches.is_empty() {
		return Ok(binary)
	}
	Path.utf8(dir).create_all!() ? |err| Failed("could not create ${dir}: ${Str.inspect(err)}")
	# A copy keeps the binary's mode, so it stays executable.
	Path.utf8(binary).copy!(Path.utf8(copy)) ? |err| Failed("could not copy ${binary}: ${Str.inspect(err)}")
	patched = patches.fold(image, |bytes, (offset, value)| put_u64(bytes, offset, value))
	Path.utf8(copy).write_bytes!(patched) ? |err| Failed("could not write ${copy}: ${Str.inspect(err)}")
	Ok(copy)
}

## Find the `p_filesz` fields Valgrind needs widened to load an ELF's symbols.
##
## Valgrind reads a binary's symbol table only once it has seen as many
## writable mappings as it expects. Two writable PT_LOAD segments that are
## adjacent in memory get mapped as one, and Valgrind allows for that only
## when the first one's file size reaches the second (`p_vaddr + p_filesz`).
## lld ends the first with `.relro_padding`, which occupies memory but not the
## file, so Valgrind waits for a mapping that never comes, reports every frame
## as `???`, and no `fun:` suppression can match.
##
## The padding is zero-filled in memory and the bytes that follow the segment
## in the file are zero too, so extending the file size over them loads the
## same image. Returns (offset, value) pairs to write as little-endian u64.
merged_rw_segment_patches : List(U8) -> List((U64, U64))
merged_rw_segment_patches = |image| {
	if !image.starts_with([0x7F, 'E', 'L', 'F', 2, 1]) {
		return []
	}
	program_headers = U64.from_le_bytes(image, 32) ?? 0
	entry_size = U16.from_le_bytes(image, 54).map_ok(|n| n.to_u64()) ?? 0
	entry_count = U16.from_le_bytes(image, 56).map_ok(|n| n.to_u64()) ?? 0
	var $patches = []
	var $previous = Err(NoSegment)
	var $index = 0
	while $index < entry_count {
		entry = program_headers + $index * entry_size
		$index = $index + 1
		kind = U32.from_le_bytes(image, entry) ?? 0
		flags = U32.from_le_bytes(image, entry + 4) ?? 0
		offset = U64.from_le_bytes(image, entry + 8) ?? 0
		address = U64.from_le_bytes(image, entry + 16) ?? 0
		file_size = U64.from_le_bytes(image, entry + 32) ?? 0
		memory_size = U64.from_le_bytes(image, entry + 40) ?? 0
		# PT_LOAD, readable and writable but not executable.
		if kind == 1 and flags.bitwise_and(7) == 6 and memory_size != 0 {
			match $previous {
				Ok(previous) => {
					padded = previous.file_size < previous.memory_size
					adjacent = previous.address + previous.memory_size == address
					in_file = previous.offset + previous.memory_size <= offset
					padding = image.sublist({ start: previous.offset + previous.file_size, len: previous.memory_size.minus_saturated(previous.file_size) })
					if padded and adjacent and in_file and padding.all(|byte| byte == 0) {
						$patches = $patches.append((previous.entry + 32, previous.memory_size))
					}
				}
				Err(NoSegment) => {}
			}
			$previous = Ok({ entry, offset, address, file_size, memory_size })
		}
	}
	$patches
}

put_u64 : List(U8), U64, U64 -> List(U8)
put_u64 = |bytes, offset, value|
	[0, 1, 2, 3, 4, 5, 6, 7].fold(
		bytes,
		|so_far, index| {
			byte = value.shr_wrap((index * 8).to_u8_wrap()).to_u8_wrap()
			so_far.set(offset + index, byte) ?? so_far
		},
	)

# Values of the spec

get : List((Str, a)), Str -> Try(a, [Missing])
get = |fields, key| fields.find_first(|(name, _)| name == key).map_ok(|(_, value)| value).map_err(|_| Missing)

text_at : Obj, Str -> Try(Str, [Missing])
text_at = |fields, key| (get(fields, key)?).text_of().map_err(|_| Missing)

## A list of strings, empty when the key is missing.
texts_at : Obj, Str -> List(Str)
texts_at = |fields, key| JsonValue.items_of(get(fields, key) ?? Null).keep_oks(JsonValue.text_of)

flag_at : Obj, Str, Bool -> Bool
flag_at = |fields, key, default|
	match get(fields, key) {
		Ok(Boolean(on)) => on
		_ => default
	}

## The digits of a number.
number_at : Obj, Str -> Try(Str, [Missing])
number_at = |fields, key|
	match get(fields, key) {
		Ok(Number(digits)) => Ok(digits)
		_ => Err(Missing)
	}

## An object, empty when the key is missing.
object_at : Obj, Str -> Obj
object_at = |fields, key| JsonValue.fields_of(get(fields, key) ?? Null)

# Helpers

from_hex : Str -> Try(List(U8), [NotHex])
from_hex = |text| {
	digits = text.to_utf8().drop_if(|byte| byte == ' ')
	if digits.len() % 2 != 0 {
		return Err(NotHex)
	}
	digits.chunks_of(2).fold_try(
		[],
		|bytes, pair|
			match pair {
				[high, low] => Ok(bytes.append(hex_digit(high)? * 16 + hex_digit(low)?))
				_ => Err(NotHex)
			},
	)
}

hex_digit : U8 -> Try(U8, [NotHex])
hex_digit = |digit|
	if digit >= '0' and digit <= '9' {
		Ok(digit - '0')
	} else if digit >= 'a' and digit <= 'f' {
		Ok(digit - 'a' + 10)
	} else if digit >= 'A' and digit <= 'F' {
		Ok(digit - 'A' + 10)
	} else {
		Err(NotHex)
	}

## Bytes as lowercase hex digits, two for each byte.
to_hex : List(U8) -> Str
to_hex = |bytes| {
	digit = |n| if (n < 10) '0' + n else 'a' + n - 10
	Str.from_utf8_lossy(bytes.fold([], |out, byte| out.append(digit(byte // 16)).append(digit(byte % 16))))
}

# Tests

matches : Str, Str -> Bool
matches = |pattern, text|
	match compile_regex(pattern) {
		Ok(regex) => Regex.is_match_str(regex, text)
		Err(_) => False
	}

# The spec's patterns, as roc-regex reads them: `^` and `$` at line ends,
# `\A` at the start only, `(?:...)`, `\w`, and `\_` for an underscore.
expect matches("program name: .*command-line-args(?:\\.exe)?", "program name: /x/command-line-args\n")
expect matches("(?:Unix argument, bytes|Windows argument, UTF-16 code units): \\[102, 111, 111\\]", "Windows argument, UTF-16 code units: [102, 111, 111]")
expect !matches("(?:Unix argument, bytes|Windows argument, UTF-16 code units): \\[102, 111, 111\\]", "Unix argument, bytes: [102, 111]")
expect matches("^cat: .*non_existent\\.txt", "Hello\ncat: non_existent.txt: No such file") and !matches("^cat: .*non\\_existent\\.txt", "Hello cat: non_existent.txt")
expect matches("^Completed in [1-9][0-9]*(\\.[0-9]{1,3})?s$", "a\nCompleted in 1.25s\nb") and !matches("^Completed in [1-9][0-9]*(\\.[0-9]{1,3})?s$", "Completed in 1.2500s")
expect matches("OsStr\\.\\w+\\(\"x\"\\)\\)\\)$", "OsStr.utf8(\"x\")))")
expect matches("command: \"[^\\n]*cmd-api(\\.exe)? --helper", "command: \"/a/b/cmd-api --helper") and !matches("command: \"[^\\n]*cmd-api(\\.exe)? --helper", "command: \"/a\n/cmd-api --helper")
expect matches("\\Astream ended", "stream ended\nmore") and !matches("\\Astream ended", "x\nstream ended")
expect matches("The temp dir path is .+", "The temp dir path is /tmp") and !matches("The temp dir path is .+", "The temp dir path is \n")
expect matches("lines\\_read: [0-9]+", "lines_read: 3") and !matches("lines\\_read: [0-9]+", "linesXread: 3")

# A pattern roc-regex cannot read is an error, not a crash.
expect compile_regex("(unclosed").is_err()

expect created_archive("Created: abc/XYZ.tar.zst  ") == Ok("abc/XYZ.tar.zst") and created_archive("Created:x.tar.zst").is_err() and created_archive("Building x.tar.zst").is_err()

expect live_handle_reports("live handles: 0\r\nother\nlive handles: 12\nlive handles: x\n") == [0, 12]

expect from_hex("6f6b0aff") == Ok([0x6F, 0x6B, 0x0A, 0xFF]) and from_hex("6").is_err() and to_hex([0, 0xAB, 0x10]) == "00ab10"

expect sources_hash([("b", [2]), ("a", [1])]) == Crypto.SHA256.hash([97, 0, 1, 0, 98, 0, 2, 0]).to_hex()

expect native_join(True, "C:\\repo", "tests/x.roc") == "C:\\repo\\tests\\x.roc" and native_join(False, "/repo/", "tests/x.roc") == "/repo/tests/x.roc"

# The relro padding of a writable segment followed by an adjacent writable
# one is folded into the first one's file size.
expect {
	elf = [0x7F, 'E', 'L', 'F', 2, 1].concat(List.repeat(0, 26)).concat(u64_bytes(64)).concat(List.repeat(0, 14)).concat([56, 0, 2, 0]).concat(List.repeat(0, 6))
	first = [1, 0, 0, 0, 6, 0, 0, 0].concat(u64_bytes(0x1000)).concat(u64_bytes(0x2000)).concat(u64_bytes(0x2000)).concat(u64_bytes(0x10)).concat(u64_bytes(0x40)).concat(u64_bytes(0x1000))
	second = [1, 0, 0, 0, 6, 0, 0, 0].concat(u64_bytes(0x1040)).concat(u64_bytes(0x2040)).concat(u64_bytes(0x2040)).concat(u64_bytes(0x8)).concat(u64_bytes(0x8)).concat(u64_bytes(0x1000))
	image = elf.concat(first).concat(second).concat(List.repeat(0, 0x1100))
	patches = merged_rw_segment_patches(image)
	patches == [(64 + 32, 0x40)] and U64.from_le_bytes(put_u64(image, 96, 0x40), 96) == Ok(0x40)
}

u64_bytes : U64 -> List(U8)
u64_bytes = |value| put_u64(List.repeat(0, 8), 0, value)

# A case key nobody reads and a value of the wrong type stop the spec from
# loading.
problem_of : Try({}, Problem) -> Str
problem_of = |result|
	match result {
		Err(Failed(message)) => message
		_ => ""
	}

expect check_fields("app", [("name", Text("x")), ("timeout", Number("2.5")), ("pty", Boolean(True)), ("send_signal", Text("SIGUSR1")), ("regex", Array([Text("\\Aok")]))], case_keys) == Ok({})
expect problem_of(check_fields("app", [("name", Text("x")), ("tiemout", Number("2"))], case_keys)) == "app: unknown key \"tiemout\""
expect problem_of(check_fields("app", [("helper", Number("1"))], case_keys)) == "app: helper must be \"http\""
expect problem_of(check_fields("app", [("pty", Text("true"))], case_keys)) == "app: pty must be true or false"
expect problem_of(check_fields("app", [("timeout", Text("7"))], case_keys)) == "app: timeout must be a number"
expect problem_of(check_fields("app", [("exit_code", Number("1.5"))], case_keys)) == "app: exit_code must be an integer"
expect problem_of(check_fields("app", [("send_signal", Text("SIGFOO"))], case_keys)).starts_with("app: send_signal must be one of SIGHUP")
expect problem_of(check_fields("app", [("regex", Array([Text("(open")]))], case_keys)).starts_with("app: regex: bad regex")
expect problem_of(check_fields("app", [("platforms", Object([("windows", Object([("enabled", Boolean(False))]))])), ("cases", Array([Object([("name", Text("c")), ("platforms", Object([("bsd", Object([]))]))])]))], app_keys)) == "app: cases c: platforms must be an object of linux, darwin, windows"

# A pattern with an unescaped `_`, `&` or `~` is refused with its case and
# its text. Escaped, they match themselves.
expect problem_of(check_fields("tests/x.roc: cases c", [("stdout_regex", Array([Text("lines_read")]))], case_keys)) == "tests/x.roc: cases c: stdout_regex: regex \"lines_read\" has an unescaped _, which roc-regex does not read as itself. Write \\_"
expect ["a&b", "a~b", "\\\\_"].all(|pattern| problem_of(check_fields("c", [("stderr_regex", Array([Text(pattern)]))], case_keys)).contains("has an unescaped"))
expect check_fields("c", [("regex", Array([Text("lines\\_read \\& \\~")]))], case_keys) == Ok({}) and matches("a\\&b\\~c", "a&b~c")

# The readers take the spec's values as the schema allows them.
expect {
	case = [("name", Text("c")), ("args", Array([Text("a"), Text("b")])), ("pty", Boolean(True)), ("timeout", Number("2.5")), ("platforms", Object([("linux", Object([("enabled", Boolean(False))]))]))]
	ctx = { root: "/r", windows: False, system: "linux", roc: "roc", no_cache: False, helper: "h" }
	texts_at(case, "args") == ["a", "b"] and texts_at(case, "contains") == [] and flag_at(case, "pty", False) and !flag_at(case, "temp_cwd", False) and number_at(case, "timeout") == Ok("2.5") and text_at(case, "cwd") == Err(Missing) and !case_enabled(ctx, case) and case_enabled({ ..ctx, system: "darwin" }, case)
}

# An app's stages: the default, then the app's own, then its system's.
expect {
	ctx = { root: "/r", windows: False, system: "windows", roc: "roc", no_cache: False, helper: "h" }
	entry = [("path", Text("a.roc")), ("stages", Object([("test", Boolean(False))])), ("platforms", Object([("windows", Object([("build", Boolean(False))]))]))]
	defaults = [("check", True), ("test", True), ("build", True)]
	stage_enabled(ctx, defaults, entry, "check") and !stage_enabled(ctx, defaults, entry, "test") and !stage_enabled(ctx, defaults, entry, "build") and stage_enabled({ ..ctx, system: "linux" }, defaults, entry, "build")
}

# An app runs from its source with its backend chosen and without the cache,
# and the options come before the app, whose arguments follow it.
expect {
	ctx = { root: "/r", windows: False, system: "darwin", roc: "/bin/roc", no_cache: False, helper: "h" }
	source_run_words(ctx, "interpreter", "/r/a.roc") == ["/bin/roc", "--opt=interpreter", "--no-cache", "--max-transitive-mb=256", "/r/a.roc"]
}

# Every signal the helper sends has an exit code.
expect {
	ctx = { root: "/r", windows: False, system: "darwin", roc: "roc", no_cache: False, helper: "h" }
	signal_exit_code(ctx, "SIGUSR1") == Ok(-30) and signal_exit_code({ ..ctx, system: "linux" }, "SIGUSR1") == Ok(-10) and signal_exit_code(ctx, "SIGFOO") == Err(UnknownSignal)
}
