import pf.Env
import pf.Path

## Files, paths and the order they are sorted in, for the scripts.
##
## Paths are written with `/`, which Windows takes too. A path read back from
## the system is turned into that form by `posix`.
Files := [].{

	## The current folder, which must be the repository root: the folder that
	## holds platform/main.roc.
	root! : () => Try(Str, [Failed(Str)])
	root! = || {
		dir = Files.cwd!()?
		if Files.is_file!("${dir}/platform/main.roc") {
			Ok(dir)
		} else {
			Err(Failed("Run this from the repository root, the folder that holds platform/main.roc"))
		}
	}

	## The nearest folder, from `dir` up, that holds every one of `markers`.
	find_root! : Str, List(Str) => Try(Str, [NoRoot])
	find_root! = |dir, markers| {
		all_found = markers.fold_try!({}, |{}, marker| if (Files.is_file!("${dir}/${marker}")) Ok({}) else Err(Missing))
		if all_found.is_ok() {
			return Ok(dir)
		}
		match Path.utf8(dir).parent() {
			Ok(parent) if Path.display(parent) != dir and Path.display(parent) != "" => Files.find_root!(Path.display(parent), markers)
			_ => Err(NoRoot)
		}
	}

	cwd! : () => Try(Str, [Failed(Str)])
	cwd! = || {
		dir = Env.cwd!() ? |_| Failed("The current folder is not available")
		Ok(Files.without_verbatim_prefix(Path.display(dir)))
	}

	## A path with its links resolved.
	canonical! : Str => Try(Str, [Failed(Str)])
	canonical! = |path| {
		resolved = Path.utf8(path).canonicalize!() ? |err| Failed("Could not resolve ${path}: ${Str.inspect(err)}")
		Ok(Files.without_verbatim_prefix(Path.display(resolved)))
	}

	## Windows resolves a path to its verbatim form, `\\?\C:\dir` or
	## `\\?\UNC\server\share`, which many programs do not take. This is the
	## same path in its usual form.
	without_verbatim_prefix : Str -> Str
	without_verbatim_prefix = |path|
		if path.starts_with("\\\\?\\UNC\\") {
			"\\\\${path.drop_prefix("\\\\?\\UNC\\")}"
		} else {
			path.drop_prefix("\\\\?\\")
		}

	read_bytes! : Str => Try(List(U8), [Failed(Str)])
	read_bytes! = |path| Path.utf8(path).read_bytes!().map_err(|err| Failed("Could not read ${path}: ${Str.inspect(err)}"))

	## A file as text, with anything that is not UTF-8 replaced.
	read_text! : Str => Try(Str, [Failed(Str)])
	read_text! = |path| Ok(Str.from_utf8_lossy(Files.read_bytes!(path)?))

	## Writes a file, making its folder first.
	write_bytes! : Str, List(U8) => Try({}, [Failed(Str)])
	write_bytes! = |path, bytes| {
		Files.make_dir!(Files.parent_of(path))?
		Path.utf8(path).write_bytes!(bytes).map_err(|err| Failed("Could not write ${path}: ${Str.inspect(err)}"))
	}

	write_text! : Str, Str => Try({}, [Failed(Str)])
	write_text! = |path, text| Files.write_bytes!(path, text.to_utf8())

	make_dir! : Str => Try({}, [Failed(Str)])
	make_dir! = |path| Path.utf8(path).create_all!().map_err(|err| Failed("Could not create ${path}: ${Str.inspect(err)}"))

	## Copies a file, making the destination's folder first.
	copy_file! : Str, Str => Try({}, [Failed(Str)])
	copy_file! = |source, destination| {
		Files.make_dir!(Files.parent_of(destination))?
		Path.utf8(source).copy!(Path.utf8(destination)).map_err(|err| Failed("Could not copy ${source} to ${destination}: ${Str.inspect(err)}"))
	}

	## Whether a path is a file, or a link to one.
	is_file! : Str => Bool
	is_file! = |path| {
		p = Path.utf8(path)
		match p.type!() {
			Ok(IsFile) => True
			Ok(IsSymLink) =>
				match p.canonicalize!() {
					Ok(target) => target.is_file!() ?? False
					Err(_) => False
				}
			_ => False
		}
	}

	## The first of the paths that is a file.
	first_file! : List(Str) => Try(Str, [NotFound])
	first_file! = |paths|
		match paths {
			[] => Err(NotFound)
			[path, .. as rest] => if (Files.is_file!(path)) Ok(path) else Files.first_file!(rest)
		}

	## The size of a file, 0 when it cannot be read.
	size! : Str => U64
	size! = |path| Path.utf8(path).size_in_bytes!() ?? 0

	## The SHA-256 of a file, in hex.
	sha256! : Str => Try(Str, [Failed(Str)])
	sha256! = |path| Ok(Crypto.SHA256.hash(Files.read_bytes!(path)?).to_hex())

	## The files directly in a folder whose names end in `suffix`, each as the
	## folder and its name, in byte order. Hidden files are left out.
	files_in! : Str, Str => Try(List(Str), [Failed(Str)])
	files_in! = |dir, suffix| {
		entries = Path.utf8(dir).list!() ? |err| Failed("Could not list ${dir}: ${Str.inspect(err)}")
		names = entries.map(|entry| Files.base_name(Path.display(entry))).keep_if(|name| name.ends_with(suffix) and !name.starts_with("."))
		Ok(names.sort_with(Files.compare).map(|name| "${dir}/${name}"))
	}

	## Every file below a folder, by its path inside it, in byte order. A link
	## to a file counts, one to a folder is not followed. A missing folder has
	## no files.
	files_under! : Str => Try(List(Str), [Failed(Str)])
	files_under! = |dir|
		if Path.utf8(dir).is_dir!() ?? False {
			Ok(Files.walk!(dir, "")?.sort_with(Files.compare))
		} else {
			Ok([])
		}

	walk! : Str, Str => Try(List(Str), [Failed(Str)])
	walk! = |root, prefix| {
		folder = if (prefix.is_empty()) root else "${root}/${prefix}"
		entries = Path.utf8(folder).list!() ? |err| Failed("Could not read ${folder}: ${Str.inspect(err)}")
		entries.fold_try!(
			[],
			|found, entry| {
				name = Files.base_name(Files.posix(Path.display(entry)))
				relative = if (prefix.is_empty()) name else "${prefix}/${name}"
				match entry.type!() {
					Ok(IsDir) => Ok(found.concat(Files.walk!(root, relative)?))
					Ok(IsFile) => Ok(found.append(relative))
					Ok(IsSymLink) => Ok(if (Files.is_file!("${root}/${relative}")) found.append(relative) else found)
					Ok(IsOther) => Ok(found)
					Err(err) => Err(Failed("Could not read ${Path.display(entry)}: ${Str.inspect(err)}"))
				}
			},
		)
	}

	## A path with `\` written as `/`.
	posix : Str -> Str
	posix = |path| path.replace_each("\\", "/")

	## A path as its folder and its file name, split at its last `/` or `\`.
	## A bare name is in `.`.
	split_path : Str -> (Str, Str)
	split_path = |path|
		match (path.split_last("/"), path.split_last("\\")) {
			(Ok(a), Ok(b)) => if (a.before.count_utf8_bytes() > b.before.count_utf8_bytes()) (a.before, a.after) else (b.before, b.after)
			(Ok(a), Err(_)) => (a.before, a.after)
			(Err(_), Ok(b)) => (b.before, b.after)
			(Err(_), Err(_)) => (".", path)
		}

	base_name : Str -> Str
	base_name = |path| Files.split_path(path).1

	parent_of : Str -> Str
	parent_of = |path| Files.split_path(path).0

	## The path of a file next to another one.
	sibling : Str, Str -> Str
	sibling = |path, name| "${Files.parent_of(path)}/${name}"

	## The extension of a file name, with its dot: nothing for `LICENSE-MIT`
	## or `.gitignore`.
	suffix_of : Str -> Str
	suffix_of = |path|
		match Files.base_name(path).split_last(".") {
			Ok({ before, after }) if !before.is_empty() and !after.is_empty() => ".${after}"
			_ => ""
		}

	## Byte order, the order every script sorts names and paths in.
	compare : Str, Str -> [Before, Same, After]
	compare = |a, b| Files.compare_bytes(a.to_utf8(), b.to_utf8())

	compare_bytes : List(U8), List(U8) -> [Before, Same, After]
	compare_bytes = |a, b|
		match (a, b) {
			([], []) => Same
			([], _) => Before
			(_, []) => After
			([x, .. as xs], [y, .. as ys]) => if (x < y) Before else if (x > y) After else Files.compare_bytes(xs, ys)
		}

	## Each item once, sorted.
	unique_sorted : List(Str) -> List(Str)
	unique_sorted = |items| Files.unique(items.sort_with(Files.compare))

	## Each item once, in the order first seen.
	unique : List(Str) -> List(Str)
	unique = |items| items.fold([], |seen, item| if (seen.contains(item)) seen else seen.append(item))
}

# Tests. They run through the scripts that import this module.

expect Files.without_verbatim_prefix("\\\\?\\C:\\repo\\platform") == "C:\\repo\\platform"
expect Files.without_verbatim_prefix("\\\\?\\UNC\\server\\share\\x") == "\\\\server\\share\\x"
expect Files.without_verbatim_prefix("/repo/platform") == "/repo/platform"
expect Files.split_path("/a/b/c.tar.zst") == ("/a/b", "c.tar.zst") and Files.split_path("C:\\a\\b.tar.zst") == ("C:\\a", "b.tar.zst") and Files.split_path("x") == (".", "x")
expect Files.suffix_of("dir.d/EXTRA.LIB") == ".LIB" and Files.suffix_of(".gitignore") == "" and Files.suffix_of("LICENSE-MIT") == ""
expect ["b", "a/b", "a-c", "B", "a"].sort_with(Files.compare) == ["B", "a", "a-c", "a/b", "b"]
expect Files.unique_sorted(["b", "a", "b"]) == ["a", "b"]
expect Files.sibling("x/Cargo.toml", "Cargo.lock") == "x/Cargo.lock" and Files.sibling("C:\\x\\Cargo.toml", "Cargo.lock") == "C:\\x/Cargo.lock" and Files.sibling("Cargo.toml", "Cargo.lock") == "./Cargo.lock"
