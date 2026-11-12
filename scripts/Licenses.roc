import Files

## The license review the notices and the Windows provenance share.
Licenses := [].{

	## The licenses a dependency may use without a further review.
	permissive : List(Str)
	permissive = [
		"MIT",
		"Apache-2.0",
		"ISC",
		"BSD-2-Clause",
		"BSD-3-Clause",
		"Zlib",
		"CC0-1.0",
		"Unlicense",
		"Unicode-3.0",
		"UPL-1.0",
		"CDLA-Permissive-2.0",
	]

	## The permissive licenses and the one exception that may go with them.
	reviewed : List(Str)
	reviewed = Licenses.permissive.append("LLVM-exception")

	## Refuses a license expression that is empty or names a license nobody
	## reviewed.
	check : Str, Str, Str -> Try({}, [Failed(Str)])
	check = |name, version, expression| {
		names = Licenses.words(expression).drop_if(|word| ["AND", "OR", "WITH"].contains(word))
		if names.is_empty() or names.any(|word| !Licenses.reviewed.contains(word)) {
			Err(Failed("Unreviewed license expression for ${name} ${version}: \"${expression}\""))
		} else {
			Ok({})
		}
	}

	## The words of a license expression, without its parentheses and `/`.
	words : Str -> List(Str)
	words = |expression| Licenses.tokens(expression).drop_if(|token| token == "(" or token == ")" or token == "/")

	## The words of a license expression and its parentheses and `/`.
	tokens : Str -> List(Str)
	tokens = |expression| {
		push = |done, word| if (word.is_empty()) done else done.append(Str.from_utf8_lossy(word))
		(found, last) = expression.to_utf8().fold(
			([], []),
			|(done, word), byte|
				if Licenses.is_license_char(byte) {
					(done, word.append(byte))
				} else if byte == '(' or byte == ')' or byte == '/' {
					(push(done, word).append(Str.from_utf8_lossy([byte])), [])
				} else {
					(push(done, word), [])
				},
		)
		push(found, last)
	}

	is_license_char : U8 -> Bool
	is_license_char = |byte| (byte >= 'A' and byte <= 'Z') or (byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or byte == '.' or byte == '+' or byte == '-'

	## Whether a file of a package, by its path inside it, is a license text:
	## named like one, and not source or code (`src/license.rs`).
	is_license_file : Str -> Bool
	is_license_file = |relative| {
		name = Files.base_name(relative)
		upper = name.with_ascii_uppercased()
		named = ["LICENSE", "LICENCE", "COPYING", "COPYRIGHT", "NOTICE", "UNLICENSE"].any(
			|prefix|
				if upper.starts_with(prefix) {
					match upper.to_utf8().get(prefix.count_utf8_bytes()) {
						Err(_) => True
						Ok(byte) => byte == '.' or byte == '_' or byte == '-'
					}
				} else {
					False
				},
		)
		named and !Licenses.code_suffixes.contains(Files.suffix_of(name))
	}

	## Files that are never license texts, even when named like one.
	code_suffixes : List(Str)
	code_suffixes = [".rs", ".c", ".cc", ".cpp", ".h", ".hpp", ".inl", ".S", ".asm", ".pl", ".py", ".sh", ".toml", ".json", ".yml", ".yaml"]
}
