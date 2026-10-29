## Hash bytes and files with `Crypt`.
app [main!] { pf: platform "../platform/main.roc" }

import pf.Crypt
import pf.Env
import pf.OsStr
import pf.Path
import pf.Stdout

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	Stdout.line!("sha256 hello: ${Crypt.hash!(Str.to_utf8("hello"), Sha256)}")?
	Stdout.line!("sha1 hello: ${Crypt.hash!(Str.to_utf8("hello"), Sha1)}")?
	Env.with_temp_dir!(
		|dir| {
			path = Path.join(dir, "site.css")
			Path.write_utf8!(path, "hello")?
			digest = Crypt.hash_file!(path, Sha256)?
			Stdout.line!("sha256 of a file: ${digest}")?
			match Crypt.hash_file!(Path.join(dir, "missing.css"), Sha256) {
				Err(PathErr(NotFound, _)) => Stdout.line!("a missing file is NotFound")
				other => Err(ExpectedNotFound(Str.inspect(other)))
			}
		},
	)
}
