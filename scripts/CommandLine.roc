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
		match Cli.parse_or_display_message(parser, raw_args, CommandLine.text_or_raw) {
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

	## An argument as text when it is valid text, and as its native units
	## otherwise. Windows hands arguments over as UTF-16, and the bytes weaver
	## gives a value parser for those are not UTF-8.
	text_or_raw : OsStr -> [Utf8(Str), UnixBytes(List(U8)), WindowsU16s(List(U16))]
	text_or_raw = |arg|
		match OsStr.to_str_try(arg) {
			Ok(text) => Utf8(text)
			Err(_) => OsStr.to_raw(arg)
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

# Valid text becomes text in every representation, and anything else keeps its units.
expect CommandLine.text_or_raw(OsStr.unix("off")) == Utf8("off")
expect CommandLine.text_or_raw(OsStr.windows("off")) == Utf8("off")
expect CommandLine.text_or_raw(OsStr.unix_bytes([111, 255])) == UnixBytes([111, 255])
expect CommandLine.text_or_raw(OsStr.windows_u16s([0xD800, 111])) == WindowsU16s([0xD800, 111])

# A choice reads the arguments of every system.
expect choice_from([OsStr.unix("--mode"), OsStr.unix("off")]) == Ok(Ok("off"))
expect choice_from([OsStr.windows("--mode"), OsStr.windows("off")]) == Ok(Ok("off"))
expect choice_from([OsStr.windows("--mode=off")]) == Ok(Ok("off"))
expect choice_from([OsStr.windows("--mode"), OsStr.windows("loud")]).is_err()
expect choice_from([OsStr.unix("--mode"), OsStr.unix_bytes([111, 255])]).is_err()
expect choice_from([OsStr.windows("--mode"), OsStr.windows_u16s([0xD800, 111])]).is_err()

choice_from : List(OsStr) -> Try(Try(Str, [NoValue]), [Help(Str), Version(Str), InvalidUsage(Str)])
choice_from = |args| {
	parser = Cli.finish_without_validating(CommandLine.choice({ long: "mode", help: "warn or off.", choices: ["warn", "off"] }), CommandLine.config({ name: "t.roc", description: "" }))
	Cli.parse_or_display_message(parser, args, CommandLine.text_or_raw)
}
