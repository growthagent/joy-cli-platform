## A JSON document whose keys are not known in advance, or may be missing.
## A document of a fixed shape is read with the builtin `Json.parse` into a
## typed record instead.
##
## An object keeps the order of its keys. A repeated key keeps its last value.
JsonValue := [Null, Boolean(Bool), Number(Str), Text(Str), Array(List(JsonValue)), Object(List((Str, JsonValue)))].{

	## Reads a JSON document.
	parse : Str -> Try(JsonValue, [BadJson(Str)])
	parse = |text| {
		bytes = text.to_utf8()
		(value, at) = JsonValue.value_at(bytes, JsonValue.skip_space(bytes, 0))?
		end = JsonValue.skip_space(bytes, at)
		if end == bytes.len() {
			Ok(value)
		} else {
			Err(BadJson("unexpected text after the value at byte ${end.to_str()}"))
		}
	}

	## The document indented by two spaces, without a final line end.
	render : JsonValue -> Str
	render = |value| JsonValue.render_at(value, "")

	## The value at a key of an object.
	field : JsonValue, Str -> Try(JsonValue, [Missing])
	field = |value, key|
		match value {
			Object(fields) => fields.find_first(|(name, _)| name == key).map_ok(|(_, item)| item).map_err(|_| Missing)
			_ => Err(Missing)
		}

	## The keys and values of an object, none for anything else.
	fields_of : JsonValue -> List((Str, JsonValue))
	fields_of = |value|
		match value {
			Object(fields) => fields
			_ => []
		}

	## The items of an array, none for anything else.
	items_of : JsonValue -> List(JsonValue)
	items_of = |value|
		match value {
			Array(items) => items
			_ => []
		}

	text_of : JsonValue -> Try(Str, [NotText])
	text_of = |value|
		match value {
			Text(text) => Ok(text)
			_ => Err(NotText)
		}

	## An array of strings.
	texts : List(Str) -> JsonValue
	texts = |items| Array(items.map(|item| Text(item)))

	## A string, or null.
	nullable : Try(Str, [Null]) -> JsonValue
	nullable = |item|
		match item {
			Ok(text) => Text(text)
			Err(Null) => Null
		}

	skip_space : List(U8), U64 -> U64
	skip_space = |bytes, from| {
		var $at = from
		while bytes.get($at).map_ok(|byte| byte == ' ' or byte == '\n' or byte == '\r' or byte == '\t') ?? False {
			$at = $at + 1
		}
		$at
	}

	value_at : List(U8), U64 -> Try((JsonValue, U64), [BadJson(Str)])
	value_at = |bytes, at|
		match bytes.get(at) {
			Ok('{') => JsonValue.object_at(bytes, JsonValue.skip_space(bytes, at + 1), [])
			Ok('[') => JsonValue.array_at(bytes, JsonValue.skip_space(bytes, at + 1), [])
			Ok('"') => {
				(text, next) = JsonValue.string_at(bytes, at + 1)?
				Ok((Text(text), next))
			}
			Ok('t') => JsonValue.word_at(bytes, at, "true", Boolean(True))
			Ok('f') => JsonValue.word_at(bytes, at, "false", Boolean(False))
			Ok('n') => JsonValue.word_at(bytes, at, "null", Null)
			Ok(c) if c == '-' or (c >= '0' and c <= '9') => {
				var $end = at + 1
				while bytes.get($end).map_ok(|d| (d >= '0' and d <= '9') or d == '.' or d == 'e' or d == 'E' or d == '+' or d == '-') ?? False {
					$end = $end + 1
				}
				Ok((Number(Str.from_utf8_lossy(bytes.sublist({ start: at, len: $end - at }))), $end))
			}
			_ => Err(BadJson("unexpected input at byte ${at.to_str()}"))
		}

	word_at : List(U8), U64, Str, JsonValue -> Try((JsonValue, U64), [BadJson(Str)])
	word_at = |bytes, at, word, value|
		if bytes.drop_first(at).starts_with(word.to_utf8()) {
			Ok((value, at + word.count_utf8_bytes()))
		} else {
			Err(BadJson("unexpected input at byte ${at.to_str()}"))
		}

	array_at : List(U8), U64, List(JsonValue) -> Try((JsonValue, U64), [BadJson(Str)])
	array_at = |bytes, at, items|
		match bytes.get(at) {
			Ok(']') if items.is_empty() => Ok((Array(items), at + 1))
			_ => {
				(item, next) = JsonValue.value_at(bytes, at)?
				after = JsonValue.skip_space(bytes, next)
				match bytes.get(after) {
					Ok(',') => JsonValue.array_at(bytes, JsonValue.skip_space(bytes, after + 1), items.append(item))
					Ok(']') => Ok((Array(items.append(item)), after + 1))
					_ => Err(BadJson("expected , or ] at byte ${after.to_str()}"))
				}
			}
		}

	object_at : List(U8), U64, List((Str, JsonValue)) -> Try((JsonValue, U64), [BadJson(Str)])
	object_at = |bytes, at, fields|
		match bytes.get(at) {
			Ok('}') if fields.is_empty() => Ok((Object(fields), at + 1))
			Ok('"') => {
				(key, after_key) = JsonValue.string_at(bytes, at + 1)?
				colon = JsonValue.skip_space(bytes, after_key)
				if bytes.get(colon) != Ok(':') {
					return Err(BadJson("expected : at byte ${colon.to_str()}"))
				}
				(item, next) = JsonValue.value_at(bytes, JsonValue.skip_space(bytes, colon + 1))?
				after = JsonValue.skip_space(bytes, next)
				kept = fields.drop_if(|(name, _)| name == key).append((key, item))
				match bytes.get(after) {
					Ok(',') => JsonValue.object_at(bytes, JsonValue.skip_space(bytes, after + 1), kept)
					Ok('}') => Ok((Object(kept), after + 1))
					_ => Err(BadJson("expected , or } at byte ${after.to_str()}"))
				}
			}
			_ => Err(BadJson("expected a key at byte ${at.to_str()}"))
		}

	## A string's text, from just after its opening quote, and where it ends.
	string_at : List(U8), U64 -> Try((Str, U64), [BadJson(Str)])
	string_at = |bytes, from| {
		var $out = []
		var $at = from
		while True {
			match bytes.get($at) {
				Err(_) => return Err(BadJson("unterminated string"))
				Ok('"') => return Ok((Str.from_utf8_lossy($out), $at + 1))
				Ok('\\') => {
					escaped =
						match bytes.get($at + 1) {
							Ok('"') => Ok('"')
							Ok('\\') => Ok('\\')
							Ok('/') => Ok('/')
							Ok('b') => Ok(8)
							Ok('f') => Ok(12)
							Ok('n') => Ok('\n')
							Ok('r') => Ok('\r')
							Ok('t') => Ok('\t')
							_ => Err(NotSimple)
						}
					match escaped {
						Ok(byte) => {
							$out = $out.append(byte)
							$at = $at + 2
						}
						Err(NotSimple) if bytes.get($at + 1) == Ok('u') => {
							(code, width) = JsonValue.code_point_at(bytes, $at)?
							$out = $out.concat(JsonValue.utf8_of(code))
							$at = $at + width
						}
						Err(NotSimple) => return Err(BadJson("unknown escape at byte ${$at.to_str()}"))
					}
				}
				Ok(byte) => {
					$out = $out.append(byte)
					$at = $at + 1
				}
			}
		}
	}

	## The code point of a `\u` escape, a surrogate pair taking two, and how
	## many bytes it took. A lone surrogate is refused.
	code_point_at : List(U8), U64 -> Try((U32, U64), [BadJson(Str)])
	code_point_at = |bytes, at| {
		lone = BadJson("lone surrogate at byte ${at.to_str()}")
		high = JsonValue.hex4(bytes, at + 2)?
		if high >= 0xDC00 and high <= 0xDFFF {
			Err(lone)
		} else if high >= 0xD800 and high <= 0xDBFF {
			if bytes.get(at + 6) != Ok('\\') or bytes.get(at + 7) != Ok('u') {
				return Err(lone)
			}
			low = JsonValue.hex4(bytes, at + 8)?
			if low >= 0xDC00 and low <= 0xDFFF {
				Ok((0x10000 + (high - 0xD800) * 0x400 + (low - 0xDC00), 12))
			} else {
				Err(lone)
			}
		} else {
			Ok((high, 6))
		}
	}

	hex4 : List(U8), U64 -> Try(U32, [BadJson(Str)])
	hex4 = |bytes, at| {
		digits = bytes.sublist({ start: at, len: 4 })
		bad = BadJson("bad \\u escape at byte ${at.to_str()}")
		if digits.len() != 4 {
			return Err(bad)
		}
		digits.fold_try(
			0,
			|sum, c| {
				digit : U32
				digit =
					if c >= '0' and c <= '9' {
						(c - '0').to_u32()
					} else if c >= 'a' and c <= 'f' {
						(c - 'a').to_u32() + 10
					} else if c >= 'A' and c <= 'F' {
						(c - 'A').to_u32() + 10
					} else {
						return Err(bad)
					}
				Ok(sum * 16 + digit)
			},
		)
	}

	## A code point as UTF-8.
	utf8_of : U32 -> List(U8)
	utf8_of = |code| {
		byte = |n| n.to_u8_wrap()
		if code < 0x80 {
			[byte(code)]
		} else if code < 0x800 {
			[byte(0xC0 + code.shr_wrap(6)), byte(0x80 + code.bitwise_and(0x3F))]
		} else if code < 0x10000 {
			[byte(0xE0 + code.shr_wrap(12)), byte(0x80 + code.shr_wrap(6).bitwise_and(0x3F)), byte(0x80 + code.bitwise_and(0x3F))]
		} else {
			[byte(0xF0 + code.shr_wrap(18)), byte(0x80 + code.shr_wrap(12).bitwise_and(0x3F)), byte(0x80 + code.shr_wrap(6).bitwise_and(0x3F)), byte(0x80 + code.bitwise_and(0x3F))]
		}
	}

	render_at : JsonValue, Str -> Str
	render_at = |value, indent|
		match value {
			Null => "null"
			Boolean(on) => if (on) "true" else "false"
			Number(text) => text
			Text(text) => JsonValue.quote(text)
			Array([]) => "[]"
			Array(items) => {
				inner = "${indent}  "
				"[\n${Str.join_with(items.map(|item| "${inner}${JsonValue.render_at(item, inner)}"), ",\n")}\n${indent}]"
			}
			Object([]) => "{}"
			Object(fields) => {
				inner = "${indent}  "
				"{\n${Str.join_with(fields.map(|(name, item)| "${inner}${JsonValue.quote(name)}: ${JsonValue.render_at(item, inner)}"), ",\n")}\n${indent}}"
			}
		}

	## A quoted string. Only the quote, the backslash and control characters
	## are escaped.
	quote : Str -> Str
	quote = |text| {
		hex = |n| if (n < 10) '0' + n else 'a' + n - 10
		escaped = text.to_utf8().fold(
			[],
			|out, byte|
				match byte {
					'"' => out.concat(['\\', '"'])
					'\\' => out.concat(['\\', '\\'])
					'\n' => out.concat(['\\', 'n'])
					'\r' => out.concat(['\\', 'r'])
					'\t' => out.concat(['\\', 't'])
					_ if byte < 0x20 => out.concat(['\\', 'u', '0', '0', hex(byte // 16), hex(byte % 16)])
					_ => out.append(byte)
				},
		)
		"\"${Str.from_utf8_lossy(escaped)}\""
	}
}

# Tests. They run through the apps that import this module, such as
# `roc test scripts/test.roc`.

expect {
	parsed = JsonValue.parse("{\"a\": [1, -2.5e3, true, null, \"x\\n\\u00e9\\ud83d\\ude00\"], \"b\": {}, \"a\": 2}")
	expected : JsonValue
	expected = Object([("b", Object([])), ("a", Number("2"))])
	parsed.map_ok(JsonValue.render) == Ok(JsonValue.render(expected))
}
expect JsonValue.parse("[\"x\\n\\u00e9\\ud83d\\ude00\"]").map_ok(|value| JsonValue.items_of(value).keep_oks(JsonValue.text_of)) == Ok(["x\né😀"])
expect ["[1,]", "{\"a\" 1}", "\"open", "[1] 2", "\"\\x\""].all(|text| JsonValue.parse(text).is_err())

# A lone surrogate is refused, also a high one before an escape that is no
# low one.
expect ["\"\\ud83d\"", "\"\\ud83d\\u0041\"", "\"\\ude00\"", "\"\\ud83d\\n\""].all(|text| JsonValue.parse(text).is_err())

expect {
	value : JsonValue
	value = Object([("target", Text("x64musl")), ("binaries", Object([("examples/a.roc", Text("é \"q\"\n"))])), ("none", Object([])), ("list", Array([Boolean(True), Null]))])
	JsonValue.render(value) == "{\n  \"target\": \"x64musl\",\n  \"binaries\": {\n    \"examples/a.roc\": \"é \\\"q\\\"\\n\"\n  },\n  \"none\": {},\n  \"list\": [\n    true,\n    null\n  ]\n}"
		and JsonValue.parse(JsonValue.render(value)).map_ok(JsonValue.render) == Ok(JsonValue.render(value))
}
