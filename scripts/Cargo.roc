import Process
import Text

## What the scripts read from Cargo: `cargo metadata` and Cargo.lock.
Cargo := [].{

	Package : { id : Str, name : Str, version : Str, license : Try(Str, [Null]), license_file : Try(Str, [Null]), source : Try(Str, [Null]), repository : Try(Str, [Null]), manifest_path : Str }

	Dep : { pkg : Str, dep_kinds : List({ kind : Try(Str, [Null]) }) }

	Resolve : { root : Try(Str, [Null]), nodes : List({ id : Str, deps : List(Cargo.Dep) }) }

	## `cargo metadata`, with its `packages` as `crates`: `packages` is a
	## reserved word in Roc, so no record field can have that name. `resolve`
	## is null with `--no-deps`.
	Metadata : { crates : List(Cargo.Package), resolve : Try(Cargo.Resolve, [Null]) }

	## Runs `cargo metadata` with more arguments and reads what it prints.
	metadata! : List(Str) => Try(Cargo.Metadata, [Failed(Str)])
	metadata! = |args| Cargo.decode(Process.capture!(["cargo", "metadata", "--format-version=1"].concat(args))?)

	decode : Str -> Try(Cargo.Metadata, [Failed(Str)])
	decode = |text| {
		renamed = Cargo.rename_packages(text) ? |NoPackages| Failed("cargo metadata has no packages")
		Json.parse(renamed).map_err(|err| Failed("cargo metadata is not what the scripts read: ${Str.inspect(err)}"))
	}

	## The text with the top-level key `packages` named `crates`, wherever it
	## is among the keys.
	rename_packages : Str -> Try(Str, [NoPackages])
	rename_packages = |text| {
		bytes = text.to_utf8()
		key = "\"packages\"".to_utf8()
		var $depth = 0
		var $in_string = False
		var $escaped = False
		var $at = 0
		while $at < bytes.len() {
			at = $at
			byte = bytes.get(at) ?? 0
			if $in_string {
				if $escaped {
					$escaped = False
				} else if byte == '\\' {
					$escaped = True
				} else if byte == '"' {
					$in_string = False
				}
			} else if byte == '{' or byte == '[' {
				$depth = $depth + 1
			} else if byte == '}' or byte == ']' {
				$depth = $depth - 1
			} else if byte == '"' {
				after = bytes.drop_first(at + key.len())
				is_key = Text.drop_leading(after, Text.is_space).starts_with([':'])
				if $depth == 1 and bytes.drop_first(at).starts_with(key) and is_key {
					return Ok(Str.from_utf8_lossy(bytes.take_first(at).concat("\"crates\"".to_utf8()).concat(after)))
				}
				$in_string = True
			}
			$at = at + 1
		}
		Err(NoPackages)
	}

	## The packages linked into the root's library: the root, unless
	## `WithoutRoot`, and every package it reaches through normal
	## dependencies. Build and dev dependencies are not linked.
	linked : Cargo.Metadata, [WithRoot, WithoutRoot] -> List(Cargo.Package)
	linked = |metadata, root_wanted|
		match metadata.resolve {
			Err(Null) => []
			Ok(resolve) => {
				root = resolve.root ?? ""
				var $wanted = []
				var $pending = [root]
				while !$pending.is_empty() {
					id = $pending.first() ?? ""
					$pending = $pending.drop_first(1)
					if !$wanted.contains(id) {
						$wanted = $wanted.append(id)
						deps = resolve.nodes.find_first(|node| node.id == id).map_ok(|node| node.deps) ?? []
						$pending = $pending.concat(deps.keep_if(|dep| dep.dep_kinds.any(|k| k.kind.is_err())).map(|dep| dep.pkg))
					}
				}
				wanted = $wanted
				keeps_root =
					match root_wanted {
						WithRoot => True
						WithoutRoot => False
					}
				metadata.crates.keep_if(|pkg| wanted.contains(pkg.id) and (pkg.id != root or keeps_root))
			}
		}

	## The checksum of every package in Cargo.lock, by name and version. A
	## local package has none.
	lock_checksums : Str -> List((Str, Str, Try(Str, [Null])))
	lock_checksums = |lock|
		lock.split_on("[[package]]").drop_first(1).map(
			|block| {
				value_of = |key| block.split_on("\n").keep_oks(|line| Cargo.toml_value(line, key)).first()
				(value_of("name") ?? "", value_of("version") ?? "", value_of("checksum").map_err(|_| Null))
			},
		)

	## The quoted value of `key = "value"`.
	toml_value : Str, Str -> Try(Str, [NoValue])
	toml_value = |line, key| {
		trimmed = line.trim()
		if !trimmed.starts_with(key) {
			return Err(NoValue)
		}
		rest = trimmed.drop_prefix(key).trim_start()
		if !rest.starts_with("=") {
			return Err(NoValue)
		}
		quoted = rest.drop_prefix("=").trim()
		if quoted.starts_with("\"") and quoted.ends_with("\"") and quoted.count_utf8_bytes() >= 2 {
			Ok(quoted.drop_prefix("\"").drop_suffix("\""))
		} else {
			Err(NoValue)
		}
	}
}

# Tests. They run through the scripts that import this module.

# Cargo.lock checksums, and none for a local package.
expect Cargo.lock_checksums("version = 4\n\n[[package]]\nname = \"a\"\nversion = \"1.0.0\"\nsource = \"registry\"\nchecksum = \"abc\"\n\n[[package]]\nname = \"host\"\nversion = \"0.1.0\"\n") == [("a", "1.0.0", Ok("abc")), ("host", "0.1.0", Err(Null))]

# `--no-deps` metadata has no resolve, so nothing is linked.
expect {
	decoded = Cargo.decode("{\"packages\":[{\"id\":\"x\",\"name\":\"x\",\"version\":\"1.0.0\",\"license\":null,\"license_file\":null,\"source\":null,\"repository\":null,\"manifest_path\":\"/x/Cargo.toml\",\"other\":1}],\"resolve\":null,\"version\":1}")
	match decoded {
		Ok(metadata) => metadata.crates.map(|pkg| pkg.name) == ["x"] and Cargo.linked(metadata, WithRoot).is_empty()
		Err(_) => False
	}
}
# The top-level packages are found wherever cargo writes them, and a nested
# key of that name or a string that holds it is not them.
expect Cargo.rename_packages("{\"version\":1, \"x\": {\"packages\": 1}, \"y\": \"\\\"packages\\\":\", \"packages\" : []}") == Ok("{\"version\":1, \"x\": {\"packages\": 1}, \"y\": \"\\\"packages\\\":\", \"crates\" : []}")
expect Cargo.rename_packages("{\"version\":1,\"x\":{\"packages\":[]}}") == Err(NoPackages)
