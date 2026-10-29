## Watch a folder tree and a single folder, and check what `Watch.next!`
## reports for edits, new files and folders, renames, removals, skipped
## folders and a changed set of folders. Run with `poll` to compare on a timer.
app [main!] { pf: platform "../platform/main.roc" }

import pf.Duration
import pf.Env
import pf.OsStr
import pf.Path
import pf.Stdout
import pf.Watch

main! : List(OsStr) => Try({}, _)
main! = |args| {
	poll =
		match args.map(OsStr.display) {
			["poll", ..] => Every(Duration.millis(30))
			_ => OsEvents
		}
	Env.with_temp_dir!(|root| watch!(root, poll))?
	Stdout.line!("Watch checks passed")
}

watch! = |root, poll| {
	client = Path.join(root, "client")
	shared = Path.join(root, "shared")
	Path.create_all!(Path.join(client, ".git"))?
	Path.create_dir!(shared)?
	Path.write_utf8!(Path.join(client, "app.roc"), "one")?
	Path.write_utf8!(Path.join(shared, "Book.roc"), "book")?

	watch = Watch.start!({ trees: [client], skip: [".git"], poll })?
	nothing = watch.next!({ timeout: Duration.millis(100) })?
	expect nothing == []
	Stdout.line!("nothing changed, nothing reported")?

	Path.write_utf8!(Path.join(client, "app.roc"), "one, edited")?
	Path.write_utf8!(Path.join(client, "catalog.roc"), "catalog")?
	Path.write_utf8!(Path.join(client, ".git/HEAD"), "skipped")?
	report!(watch, root, "an edit and a new file", 2)?

	Path.create_all!(Path.join(client, "Checkout"))?
	Path.write_utf8!(Path.join(client, "Checkout/cart.roc"), "cart")?
	report!(watch, root, "a new folder", 1)?

	Path.write_utf8!(Path.join(client, "Checkout/cart.roc"), "cart, edited")?
	report!(watch, root, "a file in the new folder", 1)?

	Path.rename!(Path.join(client, "catalog.roc"), Path.join(client, "books.roc"))?
	report!(watch, root, "a rename", 2)?

	Path.delete_all!(Path.join(client, "Checkout"))?
	report!(watch, root, "a removed folder", 1)?

	# A file in shared/ changes before shared/ is watched, and is not reported.
	Path.write_utf8!(Path.join(shared, "Book.roc"), "book, edited")?
	watch.set!({ trees: [client], folders: [shared], skip: [".git"], poll })?
	Path.write_utf8!(Path.join(shared, "Loan.roc"), "loan")?
	report!(watch, root, "a folder added later", 1)?

	# Folders named relative to the working directory are reported that way.
	Env.set_cwd!(root)?
	relative_watch = Watch.start!({ trees: [Path.utf8("client")], poll })?
	Path.write_utf8!(Path.join(client, "relative.roc"), "relative")?
	changes = collect!(relative_watch, [], 1, 20)?
	Stdout.line!("relative: ${Str.join_with(changes.map(|change| Path.display(change.path)), ", ")}")?
	Ok({})
}

## Print the changes as paths below `root`, sorted, collecting until `count`
## have arrived, since a slow machine may split one burst in two.
report! : Watch, Path, Str, U64 => Try({}, _)
report! = |watch, root, what, count| {
	seen = collect!(watch, [], count, 20)?
	lines = seen.map(|change| "${Str.inspect(change.kind)} ${relative(root, change.path)}")
	Stdout.line!("${what}: ${Str.join_with(List.sort_with(lines, compare), ", ")}")?
	Ok({})
}

collect! : Watch, List(Watch.Change), U64, U64 => Try(List(Watch.Change), _)
collect! = |watch, seen, count, tries_left|
	if seen.len() >= count or tries_left == 0 {
		Ok(seen)
	} else {
		changes = watch.next!({ timeout: Duration.millis(500) })?
		collect!(watch, seen.concat(changes), count, tries_left - 1)
	}

relative = |root, path|
	Path.display(path).drop_prefix(Path.display(root)).drop_prefix("/").drop_prefix("\\")

compare = |a, b| compare_bytes(Str.to_utf8(a), Str.to_utf8(b))

compare_bytes = |a, b|
	match (a, b) {
		([], []) => Same
		([], _) => Before
		(_, []) => After
		([x, .. as xs], [y, .. as ys]) => if (x < y) Before else if (x > y) After else compare_bytes(xs, ys)
	}
