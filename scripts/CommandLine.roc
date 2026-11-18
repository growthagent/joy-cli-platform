import pf.OsStr
import pf.Stderr
import pf.Stdout
import weaver.Base
import weaver.Builder
import weaver.Cli
import weaver.Help
import weaver.Opt

## Reads the command line of a script with weaver. `-h` and `--help` print
## the help and end the script with exit code 0, and a mistake prints the
## error and the usage and ends it with 2.
CommandLine := [].{

	read! : Cli.CliParser(data), List(OsStr) => Try(data, [Exit(I32)])
	read! = |parser, raw_args|
		match Cli.parse_or_display_message(parser, raw_args, OsStr.to_raw) {
			Ok(data) => Ok(data)
			Err(Help(message)) | Err(Version(message)) => {
				Stdout.line!(message) ?? {}
				Err(Exit(0))
			}
			Err(InvalidUsage(message)) => {
				Stderr.line!(message) ?? {}
				Err(Exit(2))
			}
		}

	## Prints an error about the command line and the usage, and ends the
	## script with exit code 2.
	fail! : Cli.CliParser(data), Str => Try(a, [Exit(I32)])
	fail! = |parser, message| {
		Stderr.line!("${message}\n\n${Help.usage_help(parser.config, [parser.config.name], parser.text_style)}") ?? {}
		Err(Exit(2))
	}

	## The settings of a script's command line. Scripts have no version, so
	## `-V` and `--version` print nothing.
	config : { name : Str, description : Str } -> Base.CliConfigParams
	config = |{ name, description }| { name, authors: [], version: "", description, text_style: Color }

	## A value that must be one of `choices`.
	one_of : List(Str), List(U8) -> Try(Str, [InvalidNumStr, InvalidValue(Str), InvalidUtf8])
	one_of = |choices, bytes| {
		value = Str.from_utf8(bytes) ? |_| InvalidUtf8
		if choices.contains(value) {
			Ok(value)
		} else {
			Err(InvalidValue("'${value}' is not one of ${Str.join_with(choices, ", ")}"))
		}
	}

	## An option that may be given once and takes one of `choices`. Its help
	## should name them.
	choice : { long : Str, help : Str, choices : List(Str) } -> Builder(Try(Str, [NoValue]), Builder.GetOptionsAction, Builder.GetOptionsAction)
	choice = |{ long, help, choices }| Opt.maybe({ short: "", long, help, type: long, parser: |arg| CommandLine.one_of(choices, Base.arg_to_bytes(arg)) })
}

# Tests. They run through the scripts that import this module.

expect CommandLine.one_of(["warn", "off"], Str.to_utf8("off")) == Ok("off")
expect CommandLine.one_of(["warn", "off"], Str.to_utf8("loud")) == Err(InvalidValue("'loud' is not one of warn, off"))
