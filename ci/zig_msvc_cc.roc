#!/usr/bin/env roc
app [main!] {
	pf: platform "https://github.com/niclas-ahden/basic-cli/releases/download/0.31.0/Ff3fkK1TjYTVxMj9V21FP24ojTJXYk314Fbo1whBZ6Yf.tar.zst",
}

# Copyright 2026 basic-cli contributors. SPDX-License-Identifier: UPL-1.0

import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Stderr

## The C compiler cc-rs runs for the Windows host: Zig's GNU-style driver
## for the MSVC x64 ABI.
##
## cc-rs passes Rust's target triple, which Zig does not read, so the
## adapter drops it and names Zig's own target. `-fms-runtime-lib=dll`
## matches /MD: it uses the DLL CRT declarations without changing the MSVC
## ABI. Every other argument reaches Zig unchanged. The Zig executable is
## the one ZIG names, else `zig` from PATH.
##
## scripts/build.roc builds this into an executable and points
## CC_x86_64_pc_windows_msvc at it. `roc test ci/zig_msvc_cc.roc` runs the
## tests.
main! : _ => Try({}, _)
main! = |raw_args| {
	args = raw_args.map(OsStr.from_raw)
	zig = Env.var!(OsStr.from_str("ZIG")) ?? OsStr.from_str("zig")
	match Cmd.new(zig).args(compiler_args(args, OsStr.display, OsStr.from_str)).inherit_stdio().run!() {
		Ok(output) =>
			match output.status {
				Exited(0) => Ok({})
				Exited(code) => Err(Exit(code))
				Signaled(_) => Err(Exit(1))
			}
		Err(err) => {
			Stderr.line!("zig_msvc_cc: could not run ${OsStr.display(zig)}: ${Str.inspect(err)}") ?? {}
			Err(Exit(1))
		}
	}
}

## Zig's arguments for cc-rs's: the target flags go, Zig's target and the
## DLL runtime come first.
compiler_args : List(a), (a -> Str), (Str -> a) -> List(a)
compiler_args = |args, text_of, from_text| {
	(kept, _) = args.fold(
		([], False),
		|(so_far, skip), arg| {
			text = text_of(arg)
			if skip {
				(so_far, False)
			} else if text == "-target" {
				(so_far, True)
			} else if text.starts_with("--target=") {
				(so_far, False)
			} else {
				(so_far.append(arg), False)
			}
		},
	)
	["cc", "-target", "x86_64-windows-msvc", "-fms-runtime-lib=dll"].map(from_text).concat(kept)
}

# Rust's target goes, Zig's target comes first, and argument boundaries stay.
expect compiler_args(["--target=x86_64-pc-windows-msvc", "-target", "x86_64-pc-windows-msvc", "-I", "directory with spaces", "-O2"], |s| s, |s| s) == ["cc", "-target", "x86_64-windows-msvc", "-fms-runtime-lib=dll", "-I", "directory with spaces", "-O2"]
expect compiler_args([], |s| s, |s| s) == ["cc", "-target", "x86_64-windows-msvc", "-fms-runtime-lib=dll"]
