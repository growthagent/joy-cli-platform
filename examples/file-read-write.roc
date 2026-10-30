## Write a UTF-8 file, read it back, and delete it.
app [main!] { pf: platform "https://github.com/growthagent/joy-cli-platform/releases/download/0.1.0-rc1/71QJT9cSt2W6XM4ovm4w6A2PAnq9uUpzn7jxT8PiTGqX.tar.zst" }

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
