## Replace every occurrence of a substring in a UTF-8 file in place.
app [main!] { pf: platform "https://github.com/growthagent/joy-cli-platform/releases/download/0.1.0-rc1/71QJT9cSt2W6XM4ovm4w6A2PAnq9uUpzn7jxT8PiTGqX.tar.zst" }

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
