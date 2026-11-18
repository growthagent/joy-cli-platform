#!/usr/bin/env roc
app [main!] {
	pf: platform "https://github.com/niclas-ahden/basic-cli/releases/download/0.32.0/3MnQnCrtfe6XS5qx58MnAGU6iWk8i1N24MYfoejcWeax.tar.zst",
	weaver: "https://github.com/lukewilliamboswell/weaver/releases/download/0.10.2/7CdYzjBAJmprmnK45oTpmH6BXt76ZASN2Ck5uZQEoWsK.tar.zst",
}

import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path
import pf.Stdout
import weaver.Cli
import weaver.Opt
import weaver.Param
import CommandLine
import Files
import Process

## Rebuilds a versioned documentation tree from published release archives.
##
##     roc scripts/restore_release_docs.roc DOCS_ROOT [--repository OWNER/NAME] [--download-root DIR]
##
## Releases attach a `docs.tar.gz` asset with the API documentation generated
## for that version. GitHub Pages is assembled from those assets, so generated
## documentation never has to be committed to this repository. Each release's
## docs go to DOCS_ROOT/<release>, and DOCS_ROOT/index.html redirects to the
## latest stable release, or before the first one to the newest release.
##
## `--repository` defaults to `GITHUB_REPOSITORY`, and the archives are
## downloaded to a temporary folder unless `--download-root` names one. Needs
## the GitHub CLI (`gh`) with a token, and `tar`, on the PATH. Exits 1 on an
## error and 2 on a bad command line.
##
## `roc test scripts/restore_release_docs.roc` runs the tests at the bottom.
main! : _ => Try({}, _)
main! = |raw_args| {
	args = CommandLine.read!(cli, raw_args)?
	repository = args.repository ?? (Env.var_str!(OsStr.from_str("GITHUB_REPOSITORY")) ?? "niclas-ahden/joy-cli-platform")
	Process.finish!(run!(args.docs_root, repository, args.download_root))
}

cli = Cli.finish_without_validating(
	{
		repository: Opt.maybe_str({ short: "", long: "repository", help: "The repository as OWNER/NAME, GITHUB_REPOSITORY by default." }),
		download_root: Opt.maybe_str({ short: "", long: "download-root", help: "The folder to download the archives to, a temporary one by default." }),
		docs_root: Param.str({ name: "docs-root", help: "The folder to rebuild the documentation in.", default: NoDefault }),
	}.Cli,
	CommandLine.config({ name: "restore_release_docs.roc", description: "Rebuild a versioned documentation tree from published release archives." }),
)

docs_asset : Str
docs_asset = "docs.tar.gz"

run! : Str, Str, Try(Str, [NoValue]) => Try({}, [Failed(Str)])
run! = |docs_root, repository, download_root| {
	restored = match download_root {
		Ok(dir) => restore!(docs_root, repository, dir)?
		Err(NoValue) => {
			dir = Env.create_temp_dir!() ? |err| Failed("Could not create a temporary folder: ${Str.inspect(err)}")
			result = restore!(docs_root, repository, Path.display(dir))
			_ = Path.delete_all!(dir)
			result?
		}
	}
	Stdout.line!("Restored ${restored.to_str()} documentation archive(s) into ${docs_root}") ?? {}
	Ok({})
}

restore! : Str, Str, Str => Try(U64, [Failed(Str)])
restore! = |docs_root, repository, download_root| {
	Files.make_dir!(docs_root)?
	releases = releases_with_docs!(repository)?
	for release in releases {
		archive = download_docs_asset!(repository, release, "${download_root}/${release}")?
		extract_docs!(archive, "${docs_root}/${release}")?
		Stdout.line!("Restored docs for ${release}") ?? {}
	}
	latest = index_version(latest_stable_release!(repository), releases)
	write_index!(docs_root, repository, latest)?
	Ok(releases.len())
}

## The version the docs root redirects to: the latest stable release, or
## before the first one the newest release, or `main` without any.
index_version : Try(Str, [NoStable]), List(Str) -> Str
index_version = |stable, releases|
	match stable {
		Ok(tag) => tag
		Err(NoStable) => releases.first() ?? "main"
	}

# GitHub

## Runs gh and returns what it printed. A failure carries what it printed on
## standard error, which is not shown.
gh! : List(Str) => Try(Str, [GhFailed(Str)])
gh! = |args|
	match Cmd.new(OsStr.from_str("gh")).args(args.map(OsStr.from_str)).stdin(Null).output_limit(MaxBytes(268_435_456)).run!() {
		Ok(output) =>
			match output.status {
				Exited(0) => Ok(Str.from_utf8_lossy(output.stdout_bytes))
				_ => Err(GhFailed(Str.from_utf8_lossy(output.stderr_bytes).trim()))
			}
		Err(CmdErr(err)) => Err(GhFailed(err.to_str()))
		Err(Interrupted) => Err(GhFailed("interrupted"))
	}

gh_output! : List(Str), Str => Try(Str, [Failed(Str)])
gh_output! = |args, description| gh!(args).map_err(|GhFailed(reason)| Failed("Failed to ${description}: ${reason}"))

## Published releases that carry a documentation archive, newest first.
## Releases from before the archive was published, and prereleases whose
## assets were removed, are not among them.
releases_with_docs! : Str => Try(List(Str), [Failed(Str)])
releases_with_docs! = |repository| Ok(nonempty_lines(gh_output!(releases_query(repository), "list releases")?))

releases_query : Str -> List(Str)
releases_query = |repository| [
	"api",
	"--paginate",
	"repos/${repository}/releases?per_page=100",
	"--jq",
	".[] | select(.draft == false) | select([.assets[].name] | index(\"${docs_asset}\")) | .tag_name",
]

latest_stable_release! : Str => Try(Str, [NoStable])
latest_stable_release! = |repository|
	match gh!(["api", "repos/${repository}/releases/latest", "--jq", ".tag_name"]) {
		Ok(output) if !output.trim().is_empty() => Ok(output.trim())
		_ => Err(NoStable)
	}

download_docs_asset! : Str, Str, Str => Try(Str, [Failed(Str)])
download_docs_asset! = |repository, release, destination| {
	Files.make_dir!(destination)?
	_ = gh_output!(["release", "download", release, "--repo", repository, "--pattern", docs_asset, "--dir", destination, "--clobber"], "download ${docs_asset} for ${release}")?
	archive = "${destination}/${docs_asset}"
	if !Files.is_file!(archive) {
		return Err(Failed("Downloaded no ${docs_asset} for ${release}"))
	}
	Ok(archive)
}

# Archives

## Extracts the docs of a release into an empty folder. Each member goes
## there without the first folder of its own path, its version folder, and a
## member at the top level is left out. Only files and folders are taken.
##
## The archive is extracted next to itself first, and only what is in it is
## then copied, so a link or a special file in it never reaches the docs.
extract_docs! : Str, Str => Try({}, [Failed(Str)])
extract_docs! = |archive, destination| {
	check_members(archive, nonempty_lines(Process.capture!(["tar", "-tzf", archive])?))?
	extracted = "${Files.parent_of(archive)}/extracted"
	_ = Path.delete_all!(Path.utf8(extracted))
	Files.make_dir!(extracted)?
	_ = Process.capture!(["tar", "-xzf", archive, "-C", extracted, "--no-same-owner"])?
	members = members_in!(archive, extracted, "")?
	_ = Path.delete_all!(Path.utf8(destination))
	Files.make_dir!(destination)?
	for (member, is_dir) in members {
		match inside_version(member) {
			Ok(inside) if is_dir => Files.make_dir!("${destination}/${inside}")?
			Ok(inside) => Files.copy_file!("${extracted}/${member}", "${destination}/${inside}")?
			Err(TopLevel) => {}
		}
	}
	_ = Path.delete_all!(Path.utf8(extracted))
	Ok({})
}

## Refuses an archive with a member outside its folder, or without anything
## inside a version folder.
check_members : Str, List(Str) -> Try({}, [Failed(Str)])
check_members = |archive, names| {
	for name in names {
		if name.starts_with("/") or path_parts(name).contains("..") {
			return Err(Failed("Unsafe member path in ${archive}: ${name}"))
		}
	}
	if names.all(|name| inside_version(name).is_err()) {
		return Err(Failed("Docs archive contains no versioned files: ${archive}"))
	}
	Ok({})
}

## What tar extracted below a folder, by path inside it, each with whether it
## is a folder. A link or a special file is refused.
members_in! : Str, Str, Str => Try(List((Str, Bool)), [Failed(Str)])
members_in! = |archive, root, prefix| {
	folder = if (prefix.is_empty()) root else "${root}/${prefix}"
	entries = Path.utf8(folder).list!() ? |err| Failed("Could not read ${folder}: ${Str.inspect(err)}")
	entries.fold_try!(
		[],
		|found, entry| {
			name = Files.base_name(Path.display(entry))
			member = if (prefix.is_empty()) name else "${prefix}/${name}"
			match entry.type!() {
				Ok(IsDir) => Ok(found.append((member, True)).concat(members_in!(archive, root, member)?))
				Ok(IsFile) => Ok(found.append((member, False)))
				_ => Err(Failed("Unsupported member in ${archive}, only files and folders may be in it: ${member}"))
			}
		},
	)
}

## A member's path without its first folder.
inside_version : Str -> Try(Str, [TopLevel])
inside_version = |name|
	match path_parts(name) {
		[_, first, .. as rest] => Ok(Str.join_with([first].concat(rest), "/"))
		_ => Err(TopLevel)
	}

## The parts of a path, without empty ones and `.`.
path_parts : Str -> List(Str)
path_parts = |path| path.split_on("/").drop_if(|part| part.is_empty() or part == ".")

# The docs root

## Writes the documentation root redirect to `docs_version`, as the shared
## `roc-lang/release-package` `docs-index` action writes it during a release.
write_index! : Str, Str, Str => Try({}, [Failed(Str)])
write_index! = |docs_root, repository, docs_version| Files.write_text!("${docs_root}/index.html", index_html(repository, docs_version))

index_html : Str, Str -> Str
index_html = |repository, docs_version| {
	repository_name = repository.split_on("/").last() ?? repository
	target = escape_html("/${repository_name}/${docs_version}/")
	version = escape_html(docs_version)
	Str.join_with(
		[
			"<!doctype html>",
			"<html lang=\"en\">",
			"<head>",
			"  <meta charset=\"utf-8\">",
			"  <meta http-equiv=\"refresh\" content=\"0; url=${target}\">",
			"  <link rel=\"canonical\" href=\"${target}\">",
			"  <title>Redirecting to ${version}</title>",
			"</head>",
			"<body>",
			"  <p><a href=\"${target}\">Redirecting to ${version}</a></p>",
			"</body>",
			"</html>",
			"",
		],
		"\n",
	)
}

## Text safe in HTML and in a quoted attribute.
escape_html : Str -> Str
escape_html = |text|
	text
		.replace_each("&", "&amp;")
		.replace_each("<", "&lt;")
		.replace_each(">", "&gt;")
		.replace_each("\"", "&quot;")
		.replace_each("'", "&#x27;")

nonempty_lines : Str -> List(Str)
nonempty_lines = |text| text.split_on("\n").map(Str.trim).drop_if(Str.is_empty)

# Tests

# The index redirects to the version under the repository's Pages path.
expect index_html("niclas-ahden/joy-cli-platform", "0.1.0-rc2") == "<!doctype html>\n<html lang=\"en\">\n<head>\n  <meta charset=\"utf-8\">\n  <meta http-equiv=\"refresh\" content=\"0; url=/joy-cli-platform/0.1.0-rc2/\">\n  <link rel=\"canonical\" href=\"/joy-cli-platform/0.1.0-rc2/\">\n  <title>Redirecting to 0.1.0-rc2</title>\n</head>\n<body>\n  <p><a href=\"/joy-cli-platform/0.1.0-rc2/\">Redirecting to 0.1.0-rc2</a></p>\n</body>\n</html>\n"
expect index_html("o/r", "a\"<b>&'").contains("content=\"0; url=/r/a&quot;&lt;b&gt;&amp;&#x27;/\"")

# The latest stable release wins, then the newest release, then main.
expect index_version(Ok("0.2.0"), ["0.3.0-rc1", "0.2.0"]) == "0.2.0"
expect index_version(Err(NoStable), ["0.1.0-rc2", "0.1.0-rc1"]) == "0.1.0-rc2"
expect index_version(Err(NoStable), []) == "main"

# Only members inside a folder are extracted, each without its own first
# folder, as Python's tarfile names them.
expect check_members("d.tar.gz", ["0.1.0/", "0.1.0/index.html", "0.1.0/search.js"]) == Ok({})
expect check_members("d.tar.gz", ["0.1.0/", "0.1.0/../../escape"]) == Err(Failed("Unsafe member path in d.tar.gz: 0.1.0/../../escape"))
expect check_members("d.tar.gz", ["/etc/passwd"]) == Err(Failed("Unsafe member path in d.tar.gz: /etc/passwd"))
expect check_members("d.tar.gz", ["0.1.0/", "./README"]) == Err(Failed("Docs archive contains no versioned files: d.tar.gz"))
expect inside_version("./0.1.0/a/index.html") == Ok("a/index.html") and inside_version("other/x.js") == Ok("x.js") and inside_version("0.1.0/") == Err(TopLevel) and inside_version("README") == Err(TopLevel)

expect releases_query("o/r") == ["api", "--paginate", "repos/o/r/releases?per_page=100", "--jq", ".[] | select(.draft == false) | select([.assets[].name] | index(\"docs.tar.gz\")) | .tag_name"]
