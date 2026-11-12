#!/usr/bin/env roc
app [main!] {
	pf: platform "https://github.com/niclas-ahden/basic-cli/releases/download/0.31.0/Ff3fkK1TjYTVxMj9V21FP24ojTJXYk314Fbo1whBZ6Yf.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.10.2/7CdYzjBAJmprmnK45oTpmH6BXt76ZASN2Ck5uZQEoWsK.tar.zst",
}

import pf.Env
import pf.Path
import pf.Stdout
import weaver.Cli
import weaver.Opt
import CommandLine
import Files
import JsonValue
import Process
import RocPin
import Text

## Pins a published platform and its package downloads for offline Nix
## builds.
##
##     roc scripts/update_nix_release.roc --release-version VERSION --url RELEASE_BUNDLE_URL [--compiler COMMIT] [--output nix/release.json]
##
## It downloads the published bundle, reads the packages its main.roc
## declares, downloads each of them and writes their URLs and hashes to the
## output. The compiler defaults to the roc-src commit pinned in flake.nix.
## Run it from the repository root, with `curl`, `tar` and `zstd` on the
## PATH. Exits 1 on an error and 2 on a bad command line.
##
## `roc test scripts/update_nix_release.roc` runs the tests at the bottom.
main! : _ => Try({}, _)
main! = |raw_args| {
	args = CommandLine.read!(cli, raw_args)?
	Process.finish!(run!({ version: args.version, url: args.url, compiler: args.compiler, output: args.output ?? "nix/release.json" }))
}

cli = Cli.finish_without_validating(
	{
		version: Opt.str({ short: "", long: "release-version", help: "The published version.", default: NoDefault }),
		url: Opt.str({ short: "", long: "url", help: "The URL of the published platform.", default: NoDefault }),
		compiler: Opt.maybe_str({ short: "", long: "compiler", help: "The Roc commit, the one the devshell builds by default." }),
		output: Opt.maybe_str({ short: "", long: "output", help: "The file to write, nix/release.json by default." }),
	}.Cli,
	CommandLine.config({ name: "update_nix_release.roc", description: "Pin a published platform and its package downloads for offline Nix builds." }),
)

Options : { version : Str, url : Str, compiler : Try(Str, [NoValue]), output : Str }

run! : Options => Try({}, [Failed(Str)])
run! = |options| {
	compiler = match options.compiler {
		Ok(commit) => commit
		Err(NoValue) => devshell_compiler(Files.read_text!("flake.nix")?)?
	}
	metadata = release_metadata!(options.version, options.url, compiler)?
	Path.utf8(options.output).write_utf8!(render_metadata(metadata)) ? |err| Failed("could not write ${options.output}: ${Str.inspect(err)}")
	Stdout.line!("Pinned joy-cli-platform ${options.version} and its package downloads in ${options.output}") ?? {}
	Ok({})
}

## A download and its Nix hash.
Pinned : { name : Str, url : Str, hash : Str }

Metadata : { version : Str, compiler : Str, url : Str, hash : Str, dependencies : List(Pinned) }

## Downloads the published bundle and every package its main.roc declares,
## so the pins follow the published archive and not this checkout.
release_metadata! : Str, Str, Str => Try(Metadata, [Failed(Str)])
release_metadata! = |version, url, compiler| {
	dir = Env.create_temp_dir_with_prefix!("nix-release-") ? |err| Failed("could not create a temporary folder: ${Str.inspect(err)}")
	result = fetch_all!(version, url, compiler, Path.display(dir))
	_ = Path.delete_all!(dir)
	result
}

fetch_all! : Str, Str, Str, Str => Try(Metadata, [Failed(Str)])
fetch_all! = |version, url, compiler, dir| {
	archive = "${dir}/platform.tar.zst"
	archive_hash = download!(url, archive)?
	source = Process.capture!(["tar", "--zstd", "-xOf", archive, "main.roc"])?
	declared = package_urls(source)?
	dependencies = declared.fold_try!(
		[],
		|pinned, (name, dependency_url)| {
			hash = download!(dependency_url, "${dir}/${name}.tar.zst")?
			Ok(pinned.append({ name, url: dependency_url, hash }))
		},
	)?
	Ok({ version, compiler, url, hash: archive_hash, dependencies })
}

## Downloads a file and returns its Nix hash. Each wait for the server is
## bounded to 60 seconds.
download! : Str, Str => Try(Str, [Failed(Str)])
download! = |url, destination| {
	Process.run!(["curl", "--fail", "--location", "--silent", "--show-error", "--connect-timeout", "60", "--speed-limit", "1", "--speed-time", "60", "--output", destination, url], []) ? |_| Failed("could not download ${url}")
	Ok(sri_hash(Files.read_bytes!(destination)?))
}

## The hash Nix writes for a fixed-output download: `sha256-` and the
## SHA-256 digest in base64.
sri_hash : List(U8) -> Str
sri_hash = |bytes| "sha256-${base64(Crypto.SHA256.hash(bytes).to_bytes())}"

## Standard base64 with padding.
base64 : List(U8) -> Str
base64 = |bytes| {
	alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".to_utf8()
	char = |index| alphabet.get(index.to_u64()) ?? '='
	var $out = []
	var $rest = bytes
	while !$rest.is_empty() {
		chunk = $rest.take_first(3)
		$rest = $rest.drop_first(3)
		a = chunk.get(0) ?? 0
		b = chunk.get(1) ?? 0
		c = chunk.get(2) ?? 0
		first = char(a // 4)
		second = char((a % 4) * 16 + b // 16)
		third = if (chunk.len() > 1) char((b % 16) * 4 + c // 64) else '='
		fourth = if (chunk.len() > 2) char(c % 64) else '='
		$out = $out.concat([first, second, third, fourth])
	}
	Str.from_utf8_lossy($out)
}

## The Roc commit the release workflow builds with, as pinned in the flake.
devshell_compiler : Str -> Try(Str, [Failed(Str)])
devshell_compiler = |flake|
	match RocPin.flake_pin(flake) {
		Ok(commit) => Ok(commit)
		Err(NoPin) => Err(Failed("No Roc commit pin found in flake.nix"))
	}

# The packages declaration

## The packages a platform's main.roc declares, by name, in order. Every
## declaration must be a released `https://....tar.zst` URL, so a dependency
## is never left out of the pins.
package_urls : Str -> Try(List((Str, Str)), [Failed(Str)])
package_urls = |source|
	match packages_block(source.to_utf8()) {
		Err(NoBlock) => Err(Failed("Published platform has no packages declaration"))
		Ok(block) =>
			match declarations(drop_comment_lines(block).to_utf8(), []) {
				Ok(urls) => Ok(urls)
				Err(Unsupported) => Err(Failed("Unsupported package declaration. Update the Nix dependency pins explicitly"))
			}
	}

## What is between the braces of the first `packages {`.
packages_block : List(U8) -> Try(Str, [NoBlock])
packages_block = |bytes| packages_block_from(bytes, 0)

packages_block_from : List(U8), U64 -> Try(Str, [NoBlock])
packages_block_from = |bytes, at| {
	word = "packages".to_utf8()
	if at + word.len() > bytes.len() {
		return Err(NoBlock)
	}
	starts_word = at == 0 or !Text.is_word_byte(bytes.get(at - 1) ?? ' ')
	if starts_word and bytes.drop_first(at).starts_with(word) {
		after = Text.drop_leading(bytes.drop_first(at + word.len()), Text.is_space)
		match after {
			['{', .. as body] =>
				match body.find_first_index(|byte| byte == '}') {
					Ok(end) => return Ok(Str.from_utf8_lossy(body.take_first(end)))
					Err(_) => {}
				}
			_ => {}
		}
	}
	packages_block_from(bytes, at + 1)
}

drop_comment_lines : Str -> Str
drop_comment_lines = |text|
	Str.join_with(text.split_on("\n").map(|line| if (line.trim_start().starts_with("#")) "" else line), "\n")

## `name: "url",` declarations, each comma optional, and nothing else but
## space.
declarations : List(U8), List((Str, Str)) -> Try(List((Str, Str)), [Unsupported])
declarations = |bytes, found|
	match Text.drop_leading(bytes, Text.is_space) {
		[] => Ok(found)
		[first, ..] as rest if is_name_start(first) => {
			name = rest.take_first(rest.find_first_index(|byte| !Text.is_word_byte(byte)) ?? rest.len())
			after_name = Text.drop_leading(rest.drop_first(name.len()), Text.is_space)
			match after_name {
				[':', .. as after_colon] =>
					match Text.drop_leading(after_colon, Text.is_space) {
						['"', .. as quoted] => {
							url = quoted.take_first(quoted.find_first_index(|byte| byte == '"' or Text.is_space(byte)) ?? quoted.len())
							after_url = quoted.drop_first(url.len())
							url_text = Str.from_utf8_lossy(url)
							is_release = url_text.starts_with("https://") and url_text.ends_with(".tar.zst") and url.len() > "https://.tar.zst".count_utf8_bytes()
							match after_url {
								['"', .. as after_quote] if is_release => {
									next = match Text.drop_leading(after_quote, Text.is_space) {
										[',', .. as more] => more
										more => more
									}
									declarations(next, with_package(found, Str.from_utf8_lossy(name), url_text))
								}
								_ => Err(Unsupported)
							}
						}
						_ => Err(Unsupported)
					}
				_ => Err(Unsupported)
			}
		}
		_ => Err(Unsupported)
	}

## A later declaration of the same name replaces the earlier one.
with_package : List((Str, Str)), Str, Str -> List((Str, Str))
with_package = |found, name, url|
	if found.any(|(seen, _)| seen == name) {
		found.map(|(seen, old)| if (seen == name) (seen, url) else (seen, old))
	} else {
		found.append((name, url))
	}

# Rendering

## The metadata as JSON with two spaces of indent, as nix/release.json has it.
render_metadata : Metadata -> Str
render_metadata = |metadata| {
	dependencies = metadata.dependencies.map(|dep| (dep.name, Object([("url", Text(dep.url)), ("hash", Text(dep.hash))])))
	value : JsonValue
	value = Object([("version", Text(metadata.version)), ("compiler", Text(metadata.compiler)), ("url", Text(metadata.url)), ("hash", Text(metadata.hash)), ("dependencies", Object(dependencies))])
	"${JsonValue.render(value)}\n"
}

is_name_start : U8 -> Bool
is_name_start = |byte| (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or byte == '_'

# Tests

# The declared packages are what gets pinned.
expect package_urls("platform \"\" packages { http: \"https://example.test/http-v2.tar.zst\", }") == Ok([("http", "https://example.test/http-v2.tar.zst")])
expect package_urls("platform \"\"\n\texposes [Cmd]\n\tpackages {\n\t\t# the http types\n\t\thttp: \"https://a.test/h.tar.zst\",\n\t\tjson : \"https://a.test/j.tar.zst\"\n\t}\n\tprovides { \"roc_main\": main! }") == Ok([("http", "https://a.test/h.tar.zst"), ("json", "https://a.test/j.tar.zst")])

# A dependency that cannot be pinned is never left out silently.
expect package_urls("platform \"\" packages { local: \"../local/main.roc\" }") == Err(Failed("Unsupported package declaration. Update the Nix dependency pins explicitly"))
expect package_urls("platform \"\" packages { http: \"https://a.test/h.tar.zst\", local: \"../local/main.roc\" }").is_err()
expect package_urls("platform \"\" packages { http: \"https://.tar.zst\" }").is_err()
expect package_urls("platform \"\"") == Err(Failed("Published platform has no packages declaration"))
expect package_urls("## packages are listed below\nplatform \"\" mypackages { x: \"https://a.test/x.tar.zst\" }") == Err(Failed("Published platform has no packages declaration"))

# Comments and an empty declaration pin nothing.
expect package_urls("platform \"\" packages {\n # no dependencies\n }") == Ok([])

# The compiler is the commit flake.nix pins, as the devshell builds it.
expect devshell_compiler("    roc-src.url = \"github:roc-lang/roc/54283d46d5bd1741dbe677f54ef4646eee4623ff?dir=src\";") == Ok("54283d46d5bd1741dbe677f54ef4646eee4623ff")
expect devshell_compiler("{}") == Err(Failed("No Roc commit pin found in flake.nix"))

# Hashes are what Nix writes for a fixed-output download.
expect sri_hash("http package".to_utf8()) == "sha256-4TFGfyftRhiuJVnTtCb+W3OPFdYmMd6e0PBP1t5xgts="
expect sri_hash([]) == "sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="
expect base64("a".to_utf8()) == "YQ==" and base64("ab".to_utf8()) == "YWI=" and base64("abc".to_utf8()) == "YWJj" and base64([]) == ""

# The metadata is written as nix/release.json has it.
expect {
	metadata = { version: "0.24.0", compiler: "54283d46d5bd1741dbe677f54ef4646eee4623ff", url: "https://example.test/platform.tar.zst", hash: "sha256-AA==", dependencies: [{ name: "http", url: "https://example.test/http-v2.tar.zst", hash: "sha256-BB==" }] }
	render_metadata(metadata) == "{\n  \"version\": \"0.24.0\",\n  \"compiler\": \"54283d46d5bd1741dbe677f54ef4646eee4623ff\",\n  \"url\": \"https://example.test/platform.tar.zst\",\n  \"hash\": \"sha256-AA==\",\n  \"dependencies\": {\n    \"http\": {\n      \"url\": \"https://example.test/http-v2.tar.zst\",\n      \"hash\": \"sha256-BB==\"\n    }\n  }\n}\n"
}
expect render_metadata({ version: "1", compiler: "c", url: "u", hash: "h", dependencies: [] }) == "{\n  \"version\": \"1\",\n  \"compiler\": \"c\",\n  \"url\": \"u\",\n  \"hash\": \"h\",\n  \"dependencies\": {}\n}\n"
