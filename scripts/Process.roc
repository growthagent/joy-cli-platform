import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path
import pf.Stderr
import pf.Stdout
import pf.System
import Files

## Running other programs from the scripts.
Process := [].{

	## Runs a command on this terminal. A failure carries the command and its
	## exit code, 128 plus the signal for one a signal stopped.
	run! : List(Str), List((Str, Str)) => Try({}, [Failed(Str), CommandFailed(Str, I32)])
	run! = |command, env| Process.run_with_stdin!(command, env, Inherit)

	## Runs a command on this terminal, with its standard input inherited or
	## given.
	run_with_stdin! : List(Str), List((Str, Str)), [Inherit, Bytes(List(U8))] => Try({}, [Failed(Str), CommandFailed(Str, I32)])
	run_with_stdin! = |command, env, stdin| {
		shown = Str.join_with(command, " ")
		base = Process.command(command)?
			.envs(env.map(|(key, value)| (OsStr.from_str(key), OsStr.from_str(value))))
			.inherit_stdio()
		cmd =
			match stdin {
				Inherit => base
				Bytes(bytes) => base.stdin(Bytes(bytes))
			}
		output = cmd.run!() ? |err| Failed("Could not run ${shown}: ${Str.inspect(err)}")
		match output.status {
			Exited(0) => Ok({})
			status => Err(CommandFailed(shown, Process.exit_code(status)))
		}
	}

	## Ends a script: a failure prints its error and exits 1, and a failed
	## command exits with its exit code. Ctrl+C ends it as interrupted.
	finish! : Try({}, [Failed(Str), CommandFailed(Str, I32), Interrupted]) => Try({}, [Exit(I32), Interrupted])
	finish! = |result|
		match result {
			Ok({}) => Ok({})
			Err(Failed(message)) => {
				Stderr.line!("error: ${message}") ?? {}
				Err(Exit(1))
			}
			Err(CommandFailed(command, code)) => {
				Stderr.line!("error: ${command} failed with exit code ${code.to_str()}") ?? {}
				Err(Exit(code))
			}
			Err(Interrupted) => Err(Interrupted)
		}

	## Prints a command, then runs it in a folder on this terminal. A failure
	## carries the command and its exit code, and Ctrl+C stops it.
	call! : List(Str), Str => Try({}, [Failed(Str), CommandFailed(Str, I32), Interrupted])
	call! = |command, cwd| {
		shown = Str.join_with(command, " ")
		Stdout.line!("+ ${shown}") ?? {}
		match Process.command(command)?.cwd(Path.utf8(cwd)).call!() {
			Ok({}) => Ok({})
			Err(BadExitStatus(output)) => Err(CommandFailed(shown, Process.exit_code(output.status)))
			Err(CmdErr(err)) => Err(Failed("${shown}: ${err.to_str()}"))
			Err(Interrupted) => Err(Interrupted)
		}
	}

	## Runs a command and returns what it printed, trimmed. What it prints on
	## standard error reaches this terminal.
	capture! : List(Str) => Try(Str, [Failed(Str)])
	capture! = |command| Process.capture_with_env!(command, [])

	## `capture!` with more environment variables.
	capture_with_env! : List(Str), List((Str, Str)) => Try(Str, [Failed(Str)])
	capture_with_env! = |command, env| {
		output = Process.command(command)?
			.envs(env.map(|(key, value)| (OsStr.from_str(key), OsStr.from_str(value))))
			.output_limit(MaxBytes(268_435_456))
			.capture!() ? |err| Failed("${Str.join_with(command, " ")} failed: ${Str.inspect(err)}")
		Ok(output.trim())
	}

	## A command for a program and its arguments.
	command : List(Str) -> Try(Cmd.Command, [Failed(Str)])
	command = |words|
		match words {
			[program, .. as args] => Ok(Cmd.new(OsStr.from_str(program)).args(args.map(OsStr.from_str)))
			[] => Err(Failed("Empty command"))
		}

	## An exit status as a process exit code: 128 plus the signal for one a
	## signal stopped, as a shell reports it.
	exit_code : Cmd.ExitStatus -> I32
	exit_code = |status|
		match status {
			Exited(code) => code
			Signaled(signal) => 128 + signal
		}

	## Finds a program the way a shell does, through PATH, or as given when it
	## names a path.
	which! : Str => Try(Str, [NotFound])
	which! = |name| Process.which_in!(name, Env.var_str!(OsStr.from_str("PATH")) ?? "")

	## `which!` with a PATH.
	which_in! : Str, Str => Try(Str, [NotFound])
	which_in! = |name, path| {
		windows = Process.is_windows!()
		extensions =
			if windows {
				pathext = (Env.var_str!(OsStr.from_str("PATHEXT")) ?? ".COM;.EXE;.BAT;.CMD").split_on(";").drop_if(Str.is_empty)
				if (pathext.any(|ext| name.with_ascii_lowercased().ends_with(ext.with_ascii_lowercased()))) [""] else pathext
			} else {
				[""]
			}
		runnable! = |candidate|
			Files.is_file!(candidate) and (windows or (Path.utf8(candidate).is_executable!() ?? False))
		dirs =
			if name.contains("/") or (windows and name.contains("\\")) {
				[""]
			} else {
				path.split_on(if (windows) ";" else ":").drop_if(Str.is_empty).map(|dir| "${dir}/")
			}
		for dir in dirs {
			for ext in extensions {
				candidate = "${dir}${name}${ext}"
				if runnable!(candidate) {
					return Ok(candidate)
				}
			}
		}
		Err(NotFound)
	}

	is_windows! : () => Bool
	is_windows! = ||
		match System.target!().os() {
			Windows(_) => True
			_ => False
		}
}
