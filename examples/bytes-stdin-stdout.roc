## Copy raw bytes from standard input to standard output and report the total.
app [main!] { pf: platform "https://github.com/growthagent/joy-cli-platform/releases/download/0.1.0-rc1/71QJT9cSt2W6XM4ovm4w6A2PAnq9uUpzn7jxT8PiTGqX.tar.zst" }

import pf.OsStr
import pf.Stdin
import pf.Stdout
import pf.Stderr

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	# Each chunk is written before the next is read, so memory use stays
	# bounded however much is piped in.
	var $total = 0.U64
	for! item in Stdin.chunks() {
		bytes = item?
		Stdout.write_bytes!(bytes)?
		$total = $total + bytes.len()
	}

	Stderr.line!("Copied ${$total.to_str()} bytes from stdin to stdout.")?

	Ok({})
}
