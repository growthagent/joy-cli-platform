#!/usr/bin/env roc
app [main!] {
	pf: platform "https://github.com/niclas-ahden/basic-cli/releases/download/0.31.0/Ff3fkK1TjYTVxMj9V21FP24ojTJXYk314Fbo1whBZ6Yf.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.10.2/7CdYzjBAJmprmnK45oTpmH6BXt76ZASN2Ck5uZQEoWsK.tar.zst",
}

import pf.Cmd
import pf.Duration
import pf.Env
import pf.OsStr
import pf.Path
import pf.Stdout
import weaver.Cli
import weaver.Opt
import CommandLine
import Files
import Process

## Checks the public OS-witness boundary with the repository's pinned Roc:
##
##     roc scripts/test_system_api.roc [--platform PLATFORM]
##
## These are compiler checks, so every OS branch is checked on every host. No
## application is executed and no native host needs to be built. Set ROC to
## use the pinned compiler, as with scripts/test.roc. Run it from the
## repository or a folder in it.
main! : _ => Try({}, _)
main! = |raw_args| {
	platform_path = CommandLine.read!(cli, raw_args)?
	Process.finish!(run!(platform_path))
}

cli = Cli.finish_without_validating(Opt.maybe_str({ short: "", long: "platform", help: "The platform main.roc to check, platform/main.roc by default." }), CommandLine.config({ name: "test_system_api.roc", description: "Check the public OS-witness boundary with the pinned Roc." }))

## A program the compiler must refuse, with words its report must hold.
Rejected : { name : Str, source : Str, diagnostics : List(Str) }

## Lines of an app, after its header.
lines : List(Str) -> Str
lines = |all| "${Str.join_with(all, "\n")}\n"

positive : Str
positive = lines([
	"import pf.System",
	"import pf.Signal",
	"import pf.Cmd",
	"import pf.IOErr",
	"",
	"unix_from_target : System.Target -> Try(System.Unix, [Windows])",
	"unix_from_target = |target|",
	"    match target.os() {",
	"        Linux(linux) => Ok(linux.unix())",
	"        MacOS(macos) => Ok(macos.unix())",
	"        Windows(_) => Err(Windows)",
	"    }",
	"",
	"catch_unix! : System.Unix => Try({}, [SignalErr(IOErr)])",
	"catch_unix! = |unix| Signal.catch!([Interrupt, Terminate(unix)])",
	"",
	"replace! : System.Unix => Try({}, [CmdErr(Cmd.Err), Interrupted])",
	"replace! = |unix| Cmd.exec!(unix, \"/bin/true\", [])",
	"",
	"main! = |_| {",
	"    target = System.target!()",
	"    _arch = target.arch()",
	"    match unix_from_target(target) {",
	"        Ok(unix) => catch_unix!(unix)?",
	"        Err(Windows) => Signal.catch!([Interrupt])?",
	"    }",
	"    Ok({})",
	"}",
])

rejected_cases : List(Rejected)
rejected_cases = {
	forged = ["Unix", "Linux", "MacOS", "Windows"].map(
		|witness| {
			name: "cannot-construct-${witness.with_ascii_lowercased()}",
			source: lines([
				"import pf.System",
				"main! = |_| {",
				"    _forged : System.${witness}",
				"    _forged = System.${witness}.{ proof: 0 }",
				"    Ok({})",
				"}",
			]),
			diagnostics: ["cannot use opaque nominal type", "System.${witness}"],
		},
	)
	forged.concat([
		{
			name: "cannot-construct-target",
			source: lines([
				"import pf.System",
				"main! = |_| {",
				"    _forged = System.Target.{",
				"        architecture: X64,",
				"        operating_system: Windows({ proof: 0 }),",
				"    }",
				"    Ok({})",
				"}",
			]),
			diagnostics: ["cannot use opaque nominal type", "System.Target"],
		},
		{
			name: "record-is-not-unix",
			source: lines(["import pf.System", "forge : System.Unix", "forge = { proof: 0 }", "main! = |_| Ok({})"]),
			diagnostics: ["type mismatch", "System.Unix"],
		},
		{
			name: "windows-is-not-unix",
			source: lines(["import pf.System", "as_unix : System.Windows -> System.Unix", "as_unix = |windows| windows", "main! = |_| Ok({})"]),
			diagnostics: ["type mismatch", "System.Windows", "System.Unix"],
		},
		{
			name: "windows-has-no-unix-method",
			source: lines(["import pf.System", "as_unix : System.Windows -> System.Unix", "as_unix = |windows| windows.unix()", "main! = |_| Ok({})"]),
			diagnostics: ["missing method", "System.Windows", "unix"],
		},
		{
			name: "exec-requires-witness",
			source: lines(["import pf.Cmd", "main! = |_| Cmd.exec!(\"/bin/true\", [])"]),
			diagnostics: ["too few args", "System.Unix"],
		},
		{
			name: "terminate-requires-witness",
			source: lines(["import pf.Signal", "main! = |_| Signal.catch!([Terminate])"]),
			diagnostics: ["type mismatch", "Signal.Request"],
		},
		{
			name: "exec-rejects-windows-witness",
			source: lines([
				"import pf.System",
				"import pf.Cmd",
				"main! = |_| {",
				"    match System.target!().os() {",
				"        Windows(windows) => Cmd.exec!(windows, \"/bin/true\", [])",
				"        _ => Ok({})",
				"    }",
				"}",
			]),
			diagnostics: ["type mismatch", "System.Windows", "System.Unix"],
		},
		{
			name: "terminate-rejects-windows-witness",
			source: lines([
				"import pf.System",
				"import pf.Signal",
				"main! = |_| {",
				"    match System.target!().os() {",
				"        Windows(windows) => Signal.catch!([Terminate(windows)])",
				"        _ => Ok({})",
				"    }",
				"}",
			]),
			diagnostics: ["type mismatch", "System.Windows", "Signal.Request"],
		},
		{
			name: "unix-has-no-decoder",
			source: lines(["import pf.System", "decoded : Try(System.Unix, _)", "decoded = Json.parse(\"{\\\"proof\\\":0}\")", "main! = |_| Ok({})"]),
			diagnostics: ["missing method", "System.Unix"],
		},
		{
			name: "unix-has-no-encoder",
			source: lines(["import pf.System", "encode : System.Unix -> Str", "encode = |unix| Json.to_str(unix)", "main! = |_| Ok({})"]),
			diagnostics: ["missing method", "System.Unix"],
		},
		{
			name: "discovery-is-effectful",
			source: lines(["import pf.System", "pure_target : {} -> System.Target", "pure_target = |_| System.target!()", "main! = |_| Ok({})"]),
			diagnostics: ["type mismatch", "effectful, but a pure function is expected"],
		},
		{
			name: "host-is-private",
			source: lines(["import pf.Host", "main! = |_| Host.signal_catch!([Interrupt])"]),
			diagnostics: ["package module is private", "pf.Host"],
		},
	])
}

run! : Try(Str, [NoValue]) => Try({}, [Failed(Str)])
run! = |given| {
	cwd = Files.cwd!()?
	root = Files.find_root!(cwd, ["platform/main.roc"]) ? |NoRoot| Failed("Run this from the repository: no platform/main.roc here or above")
	platform_path =
		match given {
			Ok(path) => if (path.starts_with("/") or (path.to_utf8().get(1) == Ok(':'))) path else "${cwd}/${path}"
			Err(NoValue) => "${root}/platform/main.roc"
		}
	platform_file = Files.canonical!(platform_path) ? |_| Failed("No such platform: ${platform_path}")
	roc = Env.var_str!(OsStr.from_str("ROC")) ?? "roc"
	# Roc rejects absolute platform specifications. A temporary folder on the
	# checkout's volume also keeps this relative reference valid on Windows.
	platform_dir = Files.parent_of(Files.posix(platform_file))
	work_parent = Files.parent_of(platform_dir)
	work = Env.create_temp_dir_in!(Path.utf8(work_parent), ".system-api-") ? |err| Failed("could not create a folder: ${Str.inspect(err)}")
	result = check_all!(roc, root, Path.display(work), platform_file)
	work.delete_all!() ?? {}
	result
}

check_all! : Str, Str, Str, Str => Try({}, [Failed(Str)])
check_all! = |roc, root, work, platform_file| {
	local_platform = relative_path(work, platform_file)
	header = "app [main!] { pf: platform \"${local_platform}\" }\n\n"
	(positive_code, positive_output) = check!(roc, root, "${work}/generic-helper.roc", "${header}${positive}")?
	if positive_code != 0 {
		return Err(Failed("Generic witness helpers must compile:\n${positive_output}"))
	}
	Stdout.line!("PASS generic witness helpers and narrowing") ?? {}
	for case in rejected_cases {
		(code, output) = check!(roc, root, "${work}/${case.name}.roc", "${header}${case.source}")?
		folded = output.with_ascii_lowercased()
		if code == 0 or case.diagnostics.any(|text| !folded.contains(text.with_ascii_lowercased())) {
			return Err(Failed("${case.name}: expected rejection containing ${Str.inspect(case.diagnostics)}, got exit ${code.to_str()}:\n${output}"))
		}
		Stdout.line!("PASS ${case.name}") ?? {}
	}
	Stdout.line!("Verified OS witness API: 1 positive and ${rejected_cases.len().to_str()} negative checks") ?? {}
	Ok({})
}

## Checks an app and returns roc's exit code and its report.
check! : Str, Str, Str, Str => Try((I32, Str), [Failed(Str)])
check! = |roc, root, app_file, source| {
	Path.utf8(app_file).write_utf8!(source) ? |err| Failed("could not write ${app_file}: ${Str.inspect(err)}")
	output = Cmd.new(OsStr.from_str(roc))
		.args(["check", app_file, "--no-cache"].map(OsStr.from_str))
		.cwd(Path.utf8(root))
		.env("NO_COLOR", "1")
		.stdout(Capture)
		.stderr(MergeWithStdout)
		.timeout(Duration.seconds(60))
		.run!()
		? |err| Failed("roc check ${app_file} did not finish: ${Str.inspect(err)}")
	Ok((Process.exit_code(output.status), output.stdout_utf8_lossy()))
}

## The path from a folder to a file, written with `/`.
relative_path : Str, Str -> Str
relative_path = |from_dir, to_file| {
	from = parts(from_dir)
	to = parts(to_file)
	common = shared_length(from, to, 0)
	ups = List.repeat("..", from.len() - common)
	Str.join_with(ups.concat(to.drop_first(common)), "/")
}

parts : Str -> List(Str)
parts = |path| path.replace_each("\\", "/").split_on("/").drop_if(|part| part.is_empty() or part == ".")

shared_length : List(Str), List(Str), U64 -> U64
shared_length = |a, b, at|
	match (a.get(at), b.get(at)) {
		(Ok(x), Ok(y)) if x == y => shared_length(a, b, at + 1)
		_ => at
	}

expect relative_path("/repo/.system-api-x1", "/repo/platform/main.roc") == "../platform/main.roc"
expect relative_path("/a/b/c", "/a/d/e.roc") == "../../d/e.roc"
expect relative_path("C:\\repo\\.system-api-x", "C:\\repo\\platform\\main.roc") == "../platform/main.roc"
expect rejected_cases.len() == 16 and rejected_cases.any(|case| case.name == "cannot-construct-macos")
