## The bytes of source text, as the scripts that read Roc headers and C
## comments take them apart.
Text := [].{

	## ASCII whitespace: space, tab, the line ends, vertical tab and form feed.
	is_space : U8 -> Bool
	is_space = |byte| byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 11 or byte == 12

	## A byte of a word: an ASCII letter or digit, `_`, or any byte of a
	## non-ASCII character, which counts as a letter as in Python's `\w`.
	is_word_byte : U8 -> Bool
	is_word_byte = |byte| (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or byte == '_' or byte >= 128

	## The bytes after the leading ones `drop` holds for.
	drop_leading : List(U8), (U8 -> Bool) -> List(U8)
	drop_leading = |bytes, drop|
		match bytes {
			[first, .. as rest] if drop(first) => Text.drop_leading(rest, drop)
			_ => bytes
		}
}

# Tests. They run through the scripts that import this module.

expect Text.drop_leading(" \t\u(b)\u(c)x ".to_utf8(), Text.is_space) == "x ".to_utf8()
expect "a_Z9é".to_utf8().all(Text.is_word_byte) and !(" -.".to_utf8().any(Text.is_word_byte))
