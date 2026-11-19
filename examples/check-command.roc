## Check whether commands are available before trying to run them.
app [main!] { pf: platform "https://github.com/growthagent/joy-cli-platform/releases/download/0.1.0-rc3/76mLk9Kjva78hsKESyupPDauSmSZYmA7HMk9oUqYPNyZ.tar.zst" }

import pf.OsStr
import pf.Stdout
import pf.Cmd

report! : Str => Try({}, _)
report! = |name| {
	status = if (Cmd.check_available!(name)) "is available" else "is not available"
	Stdout.line!("${name} ${status}")
}

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	# A command found on the PATH.
	report!("git")?

	# A name that is not installed.
	report!("definitely-not-a-real-command-xyz")?

	Ok({})
}
