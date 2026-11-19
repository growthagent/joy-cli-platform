## Print the operating system's default temporary directory.
app [main!] { pf: platform "https://github.com/growthagent/joy-cli-platform/releases/download/0.1.0-rc3/76mLk9Kjva78hsKESyupPDauSmSZYmA7HMk9oUqYPNyZ.tar.zst" }

import pf.OsStr
import pf.Stdout
import pf.Env
import pf.Path

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	temp_dir_path : Path
	temp_dir_path = Env.temp_dir!()

	Stdout.line!("The temp dir path is ${temp_dir_path.display()}")?

	Ok({})
}
