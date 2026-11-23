## Print a minimal greeting to standard output.
app [main!] { pf: platform "https://github.com/growthagent/joy-cli-platform/releases/download/0.1.0-rc5/EakfgTL6eAM3YKeEJBPmas6obyBSESSaRRXXDxP5ibnS.tar.zst" }

import pf.OsStr
import pf.Stdout

main! = |_args| {
	Stdout.line!("Hello, World!")?
	Ok({})
}
