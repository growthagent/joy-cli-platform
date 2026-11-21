## Write a UTF-8 file, read it back, and delete it.
app [main!] { pf: platform "https://github.com/growthagent/joy-cli-platform/releases/download/0.1.0-rc4/EQHYpAo8oDkf35M2DAA2nWx6Guyj5aqRf24yLk5JsSVt.tar.zst" }

import pf.OsStr
import pf.Stdout
import pf.Path

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	out_file : Path
	out_file = "out.txt"

	Stdout.line!("Writing a string to out.txt")?

	out_file.write_utf8!("a string!")?

	contents = out_file.read_utf8!()?

	# Cleanup
	out_file.delete!()?

	Stdout.line!("I read the file back. Its contents are: \"${contents}\"")?

	Ok({})
}
