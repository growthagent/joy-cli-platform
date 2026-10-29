## The platform `./joy` runs on: a command-line platform whose program can
## also serve HTTP, publish server-sent events and watch files, beside
## processes, the filesystem, the terminal and HTTP requests.
platform "joy-cli"
	requires {
		## The application entry point receives command-line arguments only; the
		## launcher-supplied program name is available from Env.program_name!.
		main! : List([Utf8(Str), UnixBytes(List(U8)), WindowsU16s(List(U16))]) => Try({}, [Exit(I32), Interrupted, ..])
	}
	exposes [Cmd, Crypt, Duration, Env, Events, File, Http, IOErr, Monotonic, OsStr, Path, Random, Server, Signal, Sleep, Sse, Stderr, Stdin, Stdout, System, Tty, Url, Utc, Watch]
	packages {
		# HTTP data types (Method, Request, Response) come from the shared
		# roc-lang/http package so apps and other packages using it see the same
		# nominal types. The platform supplies only the effectful `Http.send!`.
		http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	}
	provides {
		"roc_main": main_for_host!,
		"roc_server_respond": server_respond_for_host!,
	}
	hosted {
		"hosted_child_close": Host.child_close!,
		"hosted_child_close_stdin": Host.child_close_stdin!,
		"hosted_child_kill": Host.child_kill!,
		"hosted_child_pid": Host.child_pid!,
		"hosted_child_poll": Host.child_poll!,
		"hosted_child_read": Host.child_read!,
		"hosted_child_wait": Host.child_wait!,
		"hosted_child_write": Host.child_write!,
		"hosted_cmd_exec": Host.cmd_exec!,
		"hosted_cmd_run": Host.cmd_run!,
		"hosted_cmd_spawn": Host.cmd_spawn!,
		"hosted_cmd_spawn_leashed": Host.cmd_spawn_leashed!,
		"hosted_crypt_hash": Host.crypt_hash!,
		"hosted_crypt_hash_file": Host.crypt_hash_file!,
		"hosted_dir_create": Host.dir_create!,
		"hosted_dir_create_all": Host.dir_create_all!,
		"hosted_dir_delete_all": Host.dir_delete_all!,
		"hosted_dir_delete_empty": Host.dir_delete_empty!,
		"hosted_dir_list": Host.dir_list!,
		"hosted_env_create_temp_dir": Host.env_create_temp_dir!,
		"hosted_env_cwd": Host.env_cwd!,
		"hosted_env_dict": Host.env_dict!,
		"hosted_env_exe_path": Host.env_exe_path!,
		# Environment additions are appended to preserve existing hosted ABI numbering.
		"hosted_env_program_name": Host.env_program_name!,
		"hosted_env_set_cwd": Host.env_set_cwd!,
		"hosted_env_temp_dir": Host.env_temp_dir!,
		"hosted_env_var": Host.env_var!,
		"hosted_events_new": Host.events_new!,
		"hosted_events_publish": Host.events_publish!,
		"hosted_events_set_greeting": Host.events_set_greeting!,
		"hosted_events_streams": Host.events_streams!,
		# Appends follow the writes, not alphabetical order, so the shared result
		# type keeps its HostFileDeleteResult name in the generated glue.
		"hosted_file_append_bytes": Host.file_append_bytes!,
		"hosted_file_append_utf8": Host.file_append_utf8!,
		"hosted_file_delete": Host.file_delete!,
		# New file hosted functions are kept at the end so adding them does not
		# renumber the generated glue types for existing modules.
		"hosted_file_hard_link": Host.file_hard_link!,
		"hosted_file_is_executable": Host.file_is_executable!,
		"hosted_file_is_readable": Host.file_is_readable!,
		"hosted_file_is_writable": Host.file_is_writable!,
		"hosted_file_open_reader": Host.file_open_reader!,
		# File.Writer: a buffered writer behind a handle.
		"hosted_file_open_writer": Host.file_open_writer!,
		"hosted_file_read_bytes": Host.file_read_bytes!,
		"hosted_file_read_exactly": Host.file_read_exactly!,
		"hosted_file_read_line": Host.file_read_line!,
		"hosted_file_read_until": Host.file_read_until!,
		"hosted_file_read_up_to": Host.file_read_up_to!,
		"hosted_file_read_utf8": Host.file_read_utf8!,
		"hosted_file_reader_position": Host.file_reader_position!,
		"hosted_file_reader_seek": Host.file_reader_seek!,
		"hosted_file_rename": Host.file_rename!,
		"hosted_file_size_in_bytes": Host.file_size_in_bytes!,
		"hosted_file_time_accessed": Host.file_time_accessed!,
		"hosted_file_time_created": Host.file_time_created!,
		"hosted_file_time_modified": Host.file_time_modified!,
		"hosted_file_write_bytes": Host.file_write_bytes!,
		"hosted_file_write_utf8": Host.file_write_utf8!,
		"hosted_file_writer_flush": Host.file_writer_flush!,
		"hosted_file_writer_write_bytes": Host.file_writer_write_bytes!,
		"hosted_file_writer_write_utf8": Host.file_writer_write_utf8!,
		"hosted_http_close_body": Host.http_close_body!,
		"hosted_http_read_body": Host.http_read_body!,
		# HTTP is likewise kept at the end to avoid renumbering glue types.
		"hosted_http_send_request": Host.http_send_request!,
		"hosted_http_send_streaming": Host.http_send_streaming!,
		"hosted_monotonic_now": Host.monotonic_now!,
		"hosted_path_absolute": Host.path_absolute!,
		"hosted_path_canonicalize": Host.path_canonicalize!,
		"hosted_path_copy": Host.path_copy!,
		"hosted_path_copy_dir": Host.path_copy_dir!,
		"hosted_path_read_link": Host.path_read_link!,
		"hosted_path_set_permissions": Host.path_set_permissions!,
		"hosted_path_symlink": Host.path_symlink!,
		"hosted_path_type": Host.path_type!,
		"hosted_random_seed_u32": Host.random_seed_u32!,
		"hosted_random_seed_u64": Host.random_seed_u64!,
		"hosted_server_start": Host.server_start!,
		"hosted_server_stop": Host.server_stop!,
		"hosted_signal_catch": Host.signal_catch!,
		"hosted_signal_poll": Host.signal_poll!,
		"hosted_sleep_nanos": Host.sleep_nanos!,
		"hosted_stderr_line": Host.stderr_line!,
		"hosted_stderr_write": Host.stderr_write!,
		"hosted_stderr_write_bytes": Host.stderr_write_bytes!,
		"hosted_stdin_bytes": Host.stdin_bytes!,
		"hosted_stdin_bytes_within": Host.stdin_bytes_within!,
		"hosted_stdin_line": Host.stdin_line!,
		"hosted_stdin_read_to_end": Host.stdin_read_to_end!,
		"hosted_stdout_line": Host.stdout_line!,
		"hosted_stdout_write": Host.stdout_write!,
		"hosted_stdout_write_bytes": Host.stdout_write_bytes!,
		"hosted_system_target": System.target!,
		"hosted_tty_disable_raw_mode": Host.tty_disable_raw_mode!,
		"hosted_tty_enable_raw_mode": Host.tty_enable_raw_mode!,
		"hosted_tty_is_terminal": Host.tty_is_terminal!,
		"hosted_tty_size": Host.tty_size!,
		"hosted_utc_now": Host.utc_now!,
		"hosted_watch_next": Host.watch_next!,
		"hosted_watch_set": Host.watch_set!,
		"hosted_watch_start": Host.watch_start!,
	}
	targets: {
		inputs_dir: "targets/",
		x64mac: { inputs: ["libhost.a", app] },
		arm64mac: { inputs: ["libhost.a", app] },
		x64musl: { inputs: ["crt1.o", "libhost.a", "libunwind.a", app, "libc.a"] },
		arm64musl: { inputs: ["crt1.o", "libhost.a", "libunwind.a", app, "libc.a"] },
	}

import Cmd
import Crypt
import Duration
import Env
import Events
import File
import Host
import Http
import IOErr
import InternalHttp
import InternalServer
import Monotonic
import OsStr
import Path
import Random
import Server
import Signal
import Sleep
import Sse
import System
import Stdin
import Stdout
import Stderr
import Tty
import Url
import Utc
import Watch

## The native host removes the invocation name (argv[0]) before calling this
## function. Applications can read that value separately with Env.program_name!.
main_for_host! : List(OsStr.OsStr) => I32
main_for_host! = |args|
	match main!(args) {
		Ok({}) => 0
		Err(Exit(code)) => code
		Err(Interrupted) => {
			Tty.disable_raw_mode!() ?? {}
			if (Signal.poll!().contains(Terminate)) 143 else 130
		}
		Err(other) => {
			# Leave raw mode first, so the message is not printed without line breaks.
			Tty.disable_raw_mode!() ?? {}
			Stderr.line!("Program exited with error: ${Str.inspect(other)}") ?? {}
			1
		}
	}

server_respond_for_host! : InternalServer.Handler, InternalHttp.RequestToAndFromHost => InternalServer.ReplyToHost
server_respond_for_host! = |handler, request| InternalServer.respond_for_host!(handler, request)
