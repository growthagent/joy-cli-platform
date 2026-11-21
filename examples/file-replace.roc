## Replace every occurrence of a substring in a UTF-8 file in place.
app [main!] { pf: platform "https://github.com/growthagent/joy-cli-platform/releases/download/0.1.0-rc4/EQHYpAo8oDkf35M2DAA2nWx6Guyj5aqRf24yLk5JsSVt.tar.zst" }

import pf.OsStr
import pf.Stdout
import pf.Path

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	file : Path
	file = "greeting.txt"

	file.write_utf8!("Hello, World! Hello, Roc!")?

	# Replaces both occurrences of "Hello", not just the first.
	file.replace_utf8!("Hello", "Goodbye")?

	contents = file.read_utf8!()?

	# Cleanup
	file.delete!()?

	Stdout.line!("After replacing: \"${contents}\"")?

	Ok({})
}
