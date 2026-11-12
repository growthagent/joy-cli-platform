import Text

## The Roc commit flake.nix pins, which scripts/check_roc_pin.roc checks and
## scripts/update_nix_release.roc releases with.
RocPin := [].{

	## The commit of the first
	## `roc-src.url = "github:roc-lang/roc/<commit>?dir=src"`.
	flake_pin : Str -> Try(Str, [NoPin])
	flake_pin = |flake|
		match flake.split_first("roc-src.url") {
			Ok({ after, .. }) =>
				match RocPin.pin_after(after.to_utf8()) {
					Ok(commit) => Ok(commit)
					Err(NoPin) => RocPin.flake_pin(after)
				}
			Err(_) => Err(NoPin)
		}

	pin_after : List(U8) -> Try(Str, [NoPin])
	pin_after = |bytes| {
		is_lower_hex = |byte| (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f')
		rest = Text.drop_leading(bytes, Text.is_space)
		match rest {
			['=', .. as after_equals] => {
				quoted = Str.from_utf8_lossy(after_equals).trim_start()
				match quoted.split_first("\"github:roc-lang/roc/") {
					Ok({ before: "", after }) => {
						commit = after.to_utf8().take_first(40)
						tail = Str.from_utf8_lossy(after.to_utf8().drop_first(40))
						if commit.len() == 40 and commit.all(is_lower_hex) and tail.starts_with("?dir=src\"") {
							Ok(Str.from_utf8_lossy(commit))
						} else {
							Err(NoPin)
						}
					}
					_ => Err(NoPin)
				}
			}
			_ => Err(NoPin)
		}
	}
}

pinned : Str
pinned = "54283d46d5bd1741dbe677f54ef4646eee4623ff"

newer : Str
newer = "b797cda76e77b9e514c2192ca6513d0ba9a39070"

# The pin is the commit in the url, with any spacing around the `=`.
expect RocPin.flake_pin("    roc-src.url=\"github:roc-lang/roc/${pinned}?dir=src\";") == Ok(pinned)
expect RocPin.flake_pin("roc-src.url \t= \"github:roc-lang/roc/${pinned}?dir=src\";") == Ok(pinned)
expect RocPin.flake_pin("roc-src.url = \"github:roc-lang/roc/${pinned}\";\nroc-src.url = \"github:roc-lang/roc/${newer}?dir=src\";") == Ok(newer)
expect RocPin.flake_pin("roc-src.url = \"github:roc-lang/roc/${pinned.with_ascii_uppercased()}?dir=src\";") == Err(NoPin)
expect RocPin.flake_pin("roc-src.url = \"github:roc-lang/roc/main?dir=src\";") == Err(NoPin)
