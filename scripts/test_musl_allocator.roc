#!/usr/bin/env roc
app [main!] {
	pf: platform "https://github.com/niclas-ahden/basic-cli/releases/download/0.32.0/3MnQnCrtfe6XS5qx58MnAGU6iWk8i1N24MYfoejcWeax.tar.zst",
}

import pf.Env
import pf.Path
import pf.Stdout
import pf.System
import Files
import HostBuild
import JsonValue
import Process

## Refuses memory syscalls on every iteration of small Roc allocations (#530).
##
## It traces the allocator the platform ships, in the host's own test built
## for musl, not a glibc build. Run it from the repository root on native
## Linux x86_64, with the musl Rust target and strace installed:
##
##     roc scripts/test_musl_allocator.roc
##
## `roc test scripts/test_musl_allocator.roc` runs the tests of its parsing.
main! : _ => Try({}, _)
main! = |_args| Process.finish!(run!())

rust_target : Str
rust_target = "x86_64-unknown-linux-musl"

churn_test : Str
churn_test = "allocator::tests::repeated_small_roc_allocations_reuse_pages"

abi_test : Str
abi_test = "allocator::tests::roc_callbacks_preserve_alignment_and_reallocated_bytes"

## Startup and the test harness included, fewer memory syscalls than one in
## every 100 iterations. That holds on any machine, whatever its speed.
max_syscalls : U64
max_syscalls = 200

memory_syscalls : List(Str)
memory_syscalls = ["mmap", "mmap2", "mremap", "munmap", "madvise", "brk"]

run! : () => Try({}, [Failed(Str)])
run! = || {
	target = System.target!()
	match (target.os(), target.arch()) {
		(Linux(_), X64) => {}
		_ => return Err(Failed("Run this regression on native Linux x86_64"))
	}
	if Process.which!("strace").is_err() {
		return Err(Failed("Install strace to run the allocator regression"))
	}
	_ = Files.root!()?
	env = HostBuild.musl_build_env!(rust_target)
	built = Process.capture_with_env!(["cargo", "test", "--locked", "--release", "--lib", "--no-run", "--target", rust_target, "--message-format=json"], env)?
	executable =
		match test_executables(built) {
			[one] => one
			found => return Err(Failed("Expected one host test executable, got ${Str.inspect(found)}"))
		}
	correctness = Process.capture!([executable, "--exact", abi_test, "--nocapture", "--test-threads=1"])?
	if !correctness.contains("allocator ABI alignment and realloc checks complete") {
		return Err(Failed("Allocator ABI test did not execute:\n${correctness}"))
	}
	directory = Path.display(Env.create_temp_dir_with_prefix!("basic-cli-allocator-") ? |err| Failed("Could not create a temporary folder: ${Str.inspect(err)}"))
	result = trace_all!(executable, directory)
	_ = Path.utf8(directory).delete_all!()
	result
}

trace_all! : Str, Str => Try({}, [Failed(Str)])
trace_all! = |executable, directory| {
	sizes : List(U64)
	sizes = [900, 960, 1024, 2048]
	for size in sizes {
		summary_path = "${directory}/${size.to_str()}.strace"
		stdout = Process.capture_with_env!(
			["strace", "-f", "-c", "-qq", "-e", "trace=mmap,mremap,munmap,madvise,brk", "-o", summary_path, executable, "--exact", churn_test, "--nocapture", "--test-threads=1"],
			[("BASIC_CLI_ALLOC_CHURN_INPUT", size.to_str())],
		)?
		if !stdout.contains("allocator churn complete: input_size=${size.to_str()} iterations=20000") {
			return Err(Failed("Churn test did not execute:\n${stdout}"))
		}
		summary = Files.read_text!(summary_path)?
		count = memory_calls(summary)?
		Stdout.line!("input=${size.to_str()}: ${count.to_str()} memory syscalls for 20000 iterations") ?? {}
		if count > max_syscalls {
			return Err(Failed("Allocator syscall churn: ${count.to_str()}\n${summary}"))
		}
	}
	Ok({})
}

## The test executables of `cargo test --no-run --message-format=json`.
test_executables : Str -> List(Str)
test_executables = |messages|
	messages.split_on("\n").keep_oks(
		|line| {
			message = JsonValue.parse(line) ? |_| NotTest
			is_artifact = JsonValue.text_of(JsonValue.field(message, "reason") ?? Null) == Ok("compiler-artifact")
			is_test =
				match JsonValue.field(JsonValue.field(message, "profile") ?? Null, "test") {
					Ok(Boolean(True)) => True
					_ => False
				}
			executable = JsonValue.text_of(JsonValue.field(message, "executable") ?? Null) ? |_| NotTest
			if (is_artifact and is_test and !executable.is_empty()) Ok(executable) else Err(NotTest)
		},
	)

## The calls of the memory syscalls in an `strace -c` summary. A row of one
## whose count is not a number is an error, so a changed summary cannot pass
## as one with few calls.
memory_calls : Str -> Try(U64, [Failed(Str)])
memory_calls = |summary| {
	rows = summary.split_on("\n").fold_try(
		[],
		|found, line| {
			fields = line.split_on(" ").drop_if(Str.is_empty)
			match fields.last() {
				Ok(name) if memory_syscalls.contains(name) => {
					calls = fields.get(3) ?? ""
					count = U64.from_str(calls) ? |_| Failed("strace reported ${name} without a count of calls: ${line}")
					Ok(found.append(count))
				}
				_ => Ok(found)
			}
		},
	)?
	if rows.is_empty() {
		Err(Failed("strace did not report memory syscalls:\n${summary}"))
	} else {
		Ok(rows.sum())
	}
}

summary_fixture : Str
summary_fixture =
	\\% time     seconds  usecs/call     calls    errors syscall
	\\------ ----------- ----------- --------- --------- ----------------
	\\ 52.00    0.000052           2        25           mmap
	\\ 30.00    0.000030           3        10         1 munmap
	\\ 18.00    0.000018           6         3           brk
	\\  0.00    0.000000           0         1           write
	\\------ ----------- ----------- --------- --------- ----------------
	\\100.00    0.000100           2        39         1 total

expect memory_calls(summary_fixture) == Ok(38)
expect memory_calls("% time seconds\n").is_err()

expect {
	messages = Str.join_with(
		[
			"{\"reason\":\"compiler-artifact\",\"profile\":{\"test\":false},\"executable\":null}",
			"{\"reason\":\"compiler-artifact\",\"profile\":{\"test\":true},\"executable\":\"/t/roc_host-abc\"}",
			"{\"reason\":\"build-script-executed\",\"package_id\":\"x\"}",
			"{\"reason\":\"build-finished\",\"success\":true}",
		],
		"\n",
	)
	test_executables(messages) == ["/t/roc_host-abc"]
}

# A memory syscall row without a count is an error, not a row to skip.
expect memory_calls("calls    errors syscall\n 52.00    0.000052           2        25           mmap\n 30.00    0.000030           3                      munmap\n").is_err()
