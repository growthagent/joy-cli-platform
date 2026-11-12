#!/usr/bin/env roc
app [main!] {
	pf: platform "https://github.com/niclas-ahden/basic-cli/releases/download/0.31.0/Ff3fkK1TjYTVxMj9V21FP24ojTJXYk314Fbo1whBZ6Yf.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.10.2/7CdYzjBAJmprmnK45oTpmH6BXt76ZASN2Ck5uZQEoWsK.tar.zst",
}

import pf.Path
import weaver.Cli
import weaver.Opt
import weaver.Param
import CommandLine
import Files
import Process

## Renders docs/releases/<version>.md, filling in values only known at release
## time.
##
##     roc scripts/render_release_notes.roc TEMPLATE OUTPUT --repo OWNER/NAME --release-version VERSION --bundles BUNDLES_JSON
##
## Placeholders:
##
##     {{PLATFORM_URL}}  URL of the published platform bundle
##
## `BUNDLES_JSON` is the list of release bundles, each with its
## `artifact_file`. There must be exactly one. Any other `{{NAME}}` left in
## the notes is an error. Exits 1 on an error and 2 on a bad command line.
## `roc test scripts/render_release_notes.roc` runs the tests at the bottom.
main! : _ => Try({}, _)
main! = |raw_args| {
	options = CommandLine.read!(cli, raw_args)?
	Process.finish!(run!(options))
}

cli = Cli.finish_without_validating(
	{
		repo: Opt.str({ short: "", long: "repo", help: "The repository as OWNER/NAME.", default: NoDefault }),
		version: Opt.str({ short: "", long: "release-version", help: "The version being released.", default: NoDefault }),
		bundles: Opt.str({ short: "", long: "bundles", help: "The JSON file that lists the release bundles.", default: NoDefault }),
		template: Param.str({ name: "template", help: "The release notes with placeholders.", default: NoDefault }),
		output: Param.str({ name: "output", help: "The file to write the notes to.", default: NoDefault }),
	}.Cli,
	CommandLine.config({ name: "render_release_notes.roc", description: "Render release notes, filling in the values known at release time." }),
)

run! : { template : Str, output : Str, repo : Str, version : Str, bundles : Str } => Try({}, [Failed(Str)])
run! = |options| {
	bundles_json = read_text!(options.bundles)?
	url = platform_url(options.repo, options.version, bundles_json)?
	template = read_text!(options.template)?
	rendered = render(template, [("PLATFORM_URL", url)])?
	Path.utf8(options.output).write_utf8!(rendered) ? |err| Failed("could not write ${options.output}: ${Str.inspect(err)}")
	Ok({})
}

Bundle : { artifact_file : Str }

## The download URL of the one release bundle.
platform_url : Str, Str, Str -> Try(Str, [Failed(Str)])
platform_url = |repo, version, bundles_json| {
	parsed : Try(List(Bundle), _)
	parsed = Json.parse(bundles_json)
	bundles = parsed ? |err| Failed("the release bundles are not what this script reads: ${Str.inspect(err)}")
	match bundles {
		[bundle] => Ok("https://github.com/${repo}/releases/download/${version}/${bundle.artifact_file}")
		_ => Err(Failed("expected exactly one release bundle, found ${bundles.len().to_str()}"))
	}
}

## The template with each `{{NAME}}` replaced by its value. A placeholder
## without a value is an error.
render : Str, List((Str, Str)) -> Try(Str, [Failed(Str)])
render = |template, values| {
	rendered = values.fold(template, |text, (name, value)| text.replace_each("{{${name}}}", value))
	unknown = Files.unique_sorted(placeholders(rendered.to_utf8(), []))
	if unknown.is_empty() {
		Ok(rendered)
	} else {
		Err(Failed("unknown release notes placeholders: ${Str.join_with(unknown, ", ")}"))
	}
}

## Every `{{NAME}}` in a text, NAME being one or more of `A` to `Z` and `_`.
placeholders : List(U8), List(Str) -> List(Str)
placeholders = |bytes, found|
	match bytes {
		['{', '{', .. as rest] => {
			name = rest.take_first(rest.find_first_index(|byte| !is_name_byte(byte)) ?? rest.len())
			after = rest.drop_first(name.len())
			match after {
				['}', '}', .. as more] if !name.is_empty() => placeholders(more, found.append("{{${Str.from_utf8_lossy(name)}}}"))
				_ => placeholders(bytes.drop_first(1), found)
			}
		}
		[_, .. as rest] => placeholders(rest, found)
		[] => found
	}

is_name_byte : U8 -> Bool
is_name_byte = |byte| (byte >= 'A' and byte <= 'Z') or byte == '_'

## A file as text, with Windows line ends made Unix ones.
read_text! : Str => Try(Str, [Failed(Str)])
read_text! = |path| Ok(Files.read_text!(path)?.replace_each("\r\n", "\n").replace_each("\r", "\n"))

# Tests

expect render("app [main!] { pf: platform \"{{PLATFORM_URL}}\" }\n{{PLATFORM_URL}}", [("PLATFORM_URL", "https://x/y.tar.zst")]) == Ok("app [main!] { pf: platform \"https://x/y.tar.zst\" }\nhttps://x/y.tar.zst")

# Placeholders without a value are errors, each named once and sorted.
expect render("{{ZED}} {{PLATFORM_URL}} {{A_B}} {{ZED}}", [("PLATFORM_URL", "u")]) == Err(Failed("unknown release notes placeholders: {{A_B}}, {{ZED}}"))

# Only upper case names are placeholders.
expect render("{{lower}} {{}} {{{X}}} {{A1}}", []) == Err(Failed("unknown release notes placeholders: {{X}}"))
expect render("{ {{} }} {{lower}}", []) == Ok("{ {{} }} {{lower}}")

expect platform_url("owner/repo", "0.2.0", "[{\"artifact_file\": \"abc.tar.zst\", \"other\": 1}]") == Ok("https://github.com/owner/repo/releases/download/0.2.0/abc.tar.zst")
expect platform_url("owner/repo", "0.2.0", "[]") == Err(Failed("expected exactly one release bundle, found 0"))
expect platform_url("owner/repo", "0.2.0", "[{\"artifact_file\": \"a\"}, {\"artifact_file\": \"b\"}]") == Err(Failed("expected exactly one release bundle, found 2"))
