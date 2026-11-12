import pf.Path
import Files
import Text

## Points Roc apps at a platform URL, for the release workflow and for
## scripts/test.roc, which points the examples at the bundle it tests.
AppPlatformUrls := [].{

	## Points every app the paths name at `platform_url` and returns the apps
	## that changed. A folder names the `.roc` files directly in it, in name
	## order, and a `.roc` file names itself. Each app must declare a platform.
	update_apps! : List(Str), Str => Try(List(Str), [AppUrls(Str)])
	update_apps! = |paths, platform_url| {
		apps = paths.fold_try!([], |found, path| Ok(found.concat(apps_in!(path)?)))?
		if apps.is_empty() {
			return Err(AppUrls("No Roc apps found"))
		}
		apps.fold_try!(
			[],
			|updated, file| {
				source = Path.utf8(file).read_utf8!() ? |err| AppUrls("could not read ${file}: ${Str.inspect(err)}")
				rewritten = AppPlatformUrls.rewrite(source, platform_url) ? |NoPlatform| AppUrls("Expected exactly one platform URL in ${file}, found 0")
				if rewritten == source {
					Ok(updated)
				} else {
					Path.utf8(file).write_utf8!(rewritten) ? |err| AppUrls("could not write ${file}: ${Str.inspect(err)}")
					Ok(updated.append(file))
				}
			},
		)
	}

	## Points every script in scripts/ and ci/, the `.roc` files there with an
	## app header, at a basic-cli URL and returns the scripts that changed. Run
	## it from the repository root.
	update_scripts! : Str => Try(List(Str), [AppUrls(Str)])
	update_scripts! = |basic_cli_url| {
		files = ["scripts", "ci"].fold_try!([], |found, dir| Ok(found.concat(apps_in!(dir)?)))?
		var $scripts = []
		for file in files {
			if AppPlatformUrls.is_app(Path.utf8(file).read_utf8!() ?? "") {
				$scripts = $scripts.append(file)
			}
		}
		AppPlatformUrls.update_apps!($scripts, basic_cli_url)
	}

	## Whether a source file is an app: one with an `app [` header line. A
	## module can mention a platform in its comments and tests.
	is_app : Str -> Bool
	is_app = |source| source.starts_with("app [") or source.contains("\napp [")

	## The URL of an app's platform.
	url_of : Str -> Try(Str, [NoPlatform])
	url_of = |source| {
		bytes = source.to_utf8()
		{ open, close } = find_platform(bytes, 0)?
		Ok(Str.from_utf8_lossy(bytes.sublist({ start: open + 1, len: close - open - 1 })))
	}

	## The first `platform "..."` of an app with the quoted text replaced. The
	## word `platform` starts a word, and whitespace parts it from the quote.
	rewrite : Str, Str -> Try(Str, [NoPlatform])
	rewrite = |source, platform_url| {
		bytes = source.to_utf8()
		match find_platform(bytes, 0) {
			Ok({ open, close }) => {
				before = bytes.sublist({ start: 0, len: open + 1 })
				after = bytes.drop_first(close)
				Ok(Str.from_utf8_lossy(before.concat(platform_url.to_utf8()).concat(after)))
			}
			Err(NoPlatform) => Err(NoPlatform)
		}
	}
}

## The `.roc` files a path names.
apps_in! : Str => Try(List(Str), [AppUrls(Str)])
apps_in! = |path| {
	is_dir = Path.utf8(path).is_dir!() ?? False
	if is_dir {
		Files.files_in!(path, ".roc").map_err(|Failed(message)| AppUrls(message))
	} else if path.ends_with(".roc") {
		Ok([path])
	} else {
		Err(AppUrls("Expected a Roc app or directory: ${path}"))
	}
}

## Where the quotes around the first platform URL are.
find_platform : List(U8), U64 -> Try({ open : U64, close : U64 }, [NoPlatform])
find_platform = |bytes, from| {
	var $at = from
	word = "platform".to_utf8()
	while $at + word.len() <= bytes.len() {
		at = $at
		starts_word =
			match bytes.get(at.minus_saturated(1)) {
				Ok(previous) if at > 0 => !Text.is_word_byte(previous)
				_ => True
			}
		if starts_word and bytes.drop_first(at).starts_with(word) {
			match quoted_after(bytes, at + word.len()) {
				Ok(found) => return Ok(found)
				Err(NotQuoted) => {}
			}
		}
		$at = at + 1
	}
	Err(NoPlatform)
}

## Whitespace, then a quoted text of at least one character.
quoted_after : List(U8), U64 -> Try({ open : U64, close : U64 }, [NotQuoted])
quoted_after = |bytes, from| {
	var $at = from
	while bytes.get($at).map_ok(Text.is_space) ?? False {
		$at = $at + 1
	}
	open = $at
	if open == from or bytes.get(open) != Ok('"') {
		return Err(NotQuoted)
	}
	var $end = open + 1
	while bytes.get($end).map_ok(|byte| byte != '"') ?? False {
		$end = $end + 1
	}
	if ($end >= bytes.len() or $end == open + 1) Err(NotQuoted) else Ok({ open, close: $end })
}

expect AppPlatformUrls.rewrite("app [main!] { pf: platform \"old\" }\n", "new") == Ok("app [main!] { pf: platform \"new\" }\n")
expect AppPlatformUrls.rewrite("app [main!] {\n\tpf: platform\n\t\t\"../platform/main.roc\",\n}\n", "https://x/y.tar.zst") == Ok("app [main!] {\n\tpf: platform\n\t\t\"https://x/y.tar.zst\",\n}\n")
# Only the first platform changes, a word that ends in "platform" is not one,
# and the word needs whitespace before its quote.
expect AppPlatformUrls.rewrite("# myplatform \"a\"\nplatform\"b\" platform \"c\" platform \"d\"", "e") == Ok("# myplatform \"a\"\nplatform\"b\" platform \"e\" platform \"d\"")
expect AppPlatformUrls.rewrite("app [main!] { pf: platform \"\" }", "x") == Err(NoPlatform)
expect AppPlatformUrls.rewrite("module []", "x") == Err(NoPlatform)
expect AppPlatformUrls.url_of("app [main!] {\n\tpf: platform \"https://x/b.tar.zst\",\n}\n") == Ok("https://x/b.tar.zst") and AppPlatformUrls.url_of("module []") == Err(NoPlatform)
expect AppPlatformUrls.is_app("#!/usr/bin/env roc\napp [main!] {\n\tpf: platform \"x\",\n}\n") and !AppPlatformUrls.is_app("## The first `platform \"...\"` of an app\nX := [].{}\n")
