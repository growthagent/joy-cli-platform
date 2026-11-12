#!/usr/bin/env roc
app [main!] {
	pf: platform "https://github.com/niclas-ahden/basic-cli/releases/download/0.31.0/Ff3fkK1TjYTVxMj9V21FP24ojTJXYk314Fbo1whBZ6Yf.tar.zst",
}

import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path
import pf.Stderr
import pf.Stdout
import pf.System
import AppPlatformUrls
import Files
import Process

## Checks Roc/host ownership with a Valgrind-visible glibc diagnostic
## platform:
##
##     roc scripts/test_resource_lifetimes.roc
##
## The published Linux platform uses static musl and mimalloc. Its allocator
## is invisible to Memcheck, so zero reported allocations cannot validate
## reference-count cleanup. This Linux x86_64-only check builds an isolated
## glibc copy under the ignored target/ folder, from the glibc development
## files in /usr/lib/x86_64-linux-gnu, or in the folder GLIBC_LIB_DIR names.
##
## Memcheck cannot see a leaked resource handle. Handle boxes live in the
## host's own typed heaps (src/resources.rs), which are mapped rather than
## malloc'd, and the native value behind a leaked handle stays reachable from
## its slot. Each run therefore also sets BASIC_CLI_LIVE_HANDLES and requires
## the host to report zero live handles. scripts/test_spec.json makes the
## same assertion on every OS. Valgrind still covers everything else: memory
## errors, ordinary Roc allocations, and native values that are destroyed
## without being freed.
main! : _ => Try({}, _)
main! = |_args| Process.finish!(run!())

glibc_inputs : List(Str)
glibc_inputs = ["Scrt1.o", "crti.o", "crtn.o", "libc.so", "libgcc_s.so.1", "libm.so.6"]

apps : List(Str)
apps = ["filesystem-tools", "resource-lifetime", "process-control", "binary-file-reader", "binary-file-chunks"]

run! : () => Try({}, [Failed(Str), CommandFailed(Str, I32), Interrupted])
run! = || {
	target = System.target!()
	match (target.os(), target.arch()) {
		(Linux(_), X64) => {}
		_ => return Err(Failed("This diagnostic requires x86_64 Linux with glibc"))
	}
	if !Cmd.check_available!("valgrind") {
		return Err(Failed("Install Valgrind to run the resource-lifetime diagnostic"))
	}
	roc = Env.var_str!(OsStr.from_str("ROC")) ?? "roc"
	glibc_dir = Env.var_str!(OsStr.from_str("GLIBC_LIB_DIR")) ?? "/usr/lib/x86_64-linux-gnu"
	cwd = Files.cwd!()?
	root = Files.find_root!(cwd, ["platform/main.roc"]) ? |NoRoot| Failed("Run this from the repository: no platform/main.roc here or above")
	work = "${root}/target/resource-lifetimes-glibc"
	pf = "${work}/platform"
	inputs = "${pf}/targets/x64glibc"
	Files.make_dir!(inputs)?
	for file in Files.files_in!("${root}/platform", ".roc")? {
		Files.copy_file!(file, "${pf}/${Files.base_name(file)}")?
	}
	main_path = "${pf}/main.roc"
	header = Files.read_text!(main_path)?
	glibc_target = "inputs_dir: \"targets/\",\n        x64glibc: { inputs: [\"Scrt1.o\", \"crti.o\", \"libhost.a\", app, \"crtn.o\", \"libc.so\", \"libgcc_s.so.1\", \"libm.so.6\"] },"
	Files.write_text!(main_path, header.replace_each("inputs_dir: \"targets/\",", glibc_target))?
	for name in glibc_inputs {
		source = "${glibc_dir}/${name}"
		if !(Path.utf8(source).is_file!() ?? False) {
			return Err(Failed("Missing glibc development input: ${source}"))
		}
		Files.copy_file!(source, "${inputs}/${name}")?
	}
	Process.call!(["cargo", "build", "--locked", "--lib", "--target", "x86_64-unknown-linux-gnu"], root)?
	Files.copy_file!("${root}/target/x86_64-unknown-linux-gnu/debug/libhost.a", "${inputs}/libhost.a")?
	for name in apps {
		check_app!(roc, root, work, name)?
	}
	Ok({})
}

check_app! : Str, Str, Str, Str => Try({}, [Failed(Str), CommandFailed(Str, I32), Interrupted])
check_app! = |roc, root, work, name| {
	source = Files.read_text!("${root}/tests/resource-lifetimes/${name}.roc")?
	local = AppPlatformUrls.rewrite(source, "platform/main.roc") ? |NoPlatform| Failed("Missing platform declaration in ${name}")
	app_file = "${work}/${name}.roc"
	Files.write_text!(app_file, local)?
	binary = "${work}/${name}"
	Process.call!([roc, "build", app_file, "--target=x64glibc", "--debug", "--no-cache", "--output=${binary}"], root)?
	log = "${work}/${name}.valgrind.log"
	words = ["valgrind", "--error-exitcode=99", "--leak-check=full", "--errors-for-leak-kinds=definite,indirect", "--track-fds=yes", "--log-file=${log}", binary]
	Stdout.line!("+ ${Str.join_with(words, " ")}") ?? {}
	output = Cmd.new("valgrind")
		.args(words.drop_first(1).map(OsStr.from_str))
		.cwd(Path.utf8(work))
		.env("BASIC_CLI_LIVE_HANDLES", "1")
		.stdin(Null)
		.stdout(Inherit)
		.stderr(Capture)
		.output_limit(NoLimit)
		.run!()
		? |err| Failed("valgrind did not run: ${Str.inspect(err)}")
	errors = output.stderr_utf8_lossy()
	Stderr.write!(errors) ?? {}
	match output.status {
		Exited(0) => {}
		status => return Err(CommandFailed("valgrind ${binary}", Process.exit_code(status)))
	}
	# Child processes inherit the variable and may report too.
	reports = errors.split_on("\n").keep_oks(|line| if (line.starts_with("live handles: ")) Ok(line.drop_prefix("live handles: ")) else Err(NotAReport))
	counted = reports.keep_if(|count| !count.is_empty() and count.to_utf8().all(|byte| byte >= '0' and byte <= '9'))
	if counted.is_empty() or counted.any(|count| count != "0") {
		return Err(Failed("${name}: resource handles were still live at exit"))
	}
	if !saw_allocations(Files.read_text!(log)?) {
		return Err(Failed("Valgrind did not observe heap allocations: ${log}"))
	}
	Stdout.line!("Verified native ownership: ${log}") ?? {}
	Ok({})
}

## Whether a Valgrind log reports at least one allocation:
## `total heap usage: N allocs` with N not zero.
saw_allocations : Str -> Bool
saw_allocations = |text|
	text.split_on("total heap usage: ").drop_first(1).any(
		|after| {
			bytes = after.to_utf8()
			first = bytes.first() ?? 0
			number = bytes.take_first(bytes.find_first_index(|byte| !((byte >= '0' and byte <= '9') or byte == ',')) ?? bytes.len())
			rest = bytes.drop_first(number.len())
			first >= '1' and first <= '9' and rest.starts_with(" allocs".to_utf8())
		},
	)

expect saw_allocations("==1== HEAP SUMMARY:\n==1==   total heap usage: 1,234 allocs, 1,234 frees\n")
expect !saw_allocations("==1==   total heap usage: 0 allocs, 0 frees\n")
expect !saw_allocations("no summary")
