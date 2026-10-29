import Duration
import Host
import InternalWatch
import IOErr
import Path
import Resource

## Learn of changed files from the operating system: inotify on Linux,
## FSEvents on macOS and ReadDirectoryChangesW on Windows.
##
## A watch is on folders, never on single files: an editor that saves by
## writing a new file and renaming it over the old one ends a watch on the
## file, while the folder sees the rename. `folders` are watched alone, and
## `trees` with every folder below them, a new folder included as soon as it
## appears. Folders whose name is in `skip` are never entered.
##
## What [next!] reports comes from comparing each file's size and time of
## change with what the watch saw before, so a burst of events for one save
## is one change, and an event that changed nothing is none. When the
## operating system drops events, the watch compares every file it watches,
## so a lost event never means a missed change.
##
## `poll: Every(interval)` compares on a timer instead, for filesystems that
## send no events, such as some network mounts and folders shared into a VM.
##
## ```roc
## watch = Watch.start!({ trees: [Path.utf8("client")], skip: [".git"] })?
## changes = watch.next!({ timeout: Duration.seconds(1) })?
## ```
##
## The watch stops when its last reference is released.
Watch :: { host : Resource.Watcher }.{

	## What to watch.
	Config := {
		folders : List(Path) ?? [],
		trees : List(Path) ?? [],
		skip : List(Str) ?? [],
		poll : [OsEvents, Every(Duration)] ?? OsEvents,
	}

	## A file that appeared, changed or disappeared since the last report. A
	## rename is a `Removed` and a `Created`. Paths start with the folder or
	## tree they were found in.
	Change : { path : Path, kind : [Created, Modified, Removed] }

	## `WatchLimit` means the operating system has no watches left, and its
	## message names the setting that raises the limit.
	Err : [WatchErr(IOErr), WatchLimit(Str)]

	## Start watching. Folders that do not exist are an error.
	start! : Config => Try(Watch, [WatchErr(IOErr), WatchLimit(Str), Interrupted])
	start! = |config|
		match Host.watch_start!(to_host_config(config)) {
			Ok(host) => Ok({ host: host })
			Err(WatchErr(err)) => Err(WatchErr(err))
			Err(WatchLimit(message)) => Err(WatchLimit(message))
			Err(Interrupted) => Err(Interrupted)
		}

	## Watch other folders from now on. Folders watched both before and after
	## keep their state, so changes in them are not lost.
	set! : Watch, Config => Try({}, [WatchErr(IOErr), WatchLimit(Str), Interrupted])
	set! = |watch, config|
		match Host.watch_set!(watch.host, to_host_config(config)) {
			Ok({}) => Ok({})
			Err(WatchErr(err)) => Err(WatchErr(err))
			Err(WatchLimit(message)) => Err(WatchLimit(message))
			Err(Interrupted) => Err(Interrupted)
		}

	## How long [next!] waits for a change, and how long it then waits for
	## the files to settle.
	NextOptions := { timeout : Duration, quiet : Duration ?? Duration.millis(50) }

	## Wait for changes and report them, or an empty list when `timeout`
	## passes without one. Once something changed, the watch waits until
	## nothing has changed for `quiet`, so a save, a `git checkout` or a
	## formatter run is reported as one list.
	next! : Watch, NextOptions => Try(List(Change), [WatchErr(IOErr), WatchLimit(Str), Interrupted])
	next! = |watch, options|
		match Host.watch_next!(watch.host, Duration.to_nanos(options.timeout), Duration.to_nanos(options.quiet)) {
			Ok(changes) => Ok(changes.map(|{ path, kind }| { path: Path.from_raw(path), kind }))
			Err(WatchErr(err)) => Err(WatchErr(err))
			Err(WatchLimit(message)) => Err(WatchLimit(message))
			Err(Interrupted) => Err(Interrupted)
		}

	to_inspect : Watch -> Str
	to_inspect = |_| "Watch(<opaque>)"
}

to_host_config : Watch.Config -> InternalWatch.ConfigToHost
to_host_config = |config| {
	folders: config.folders.map(Path.to_raw),
	trees: config.trees.map(Path.to_raw),
	skip: config.skip,
	poll_nanos: match config.poll {
		OsEvents => 0
		Every(interval) => if (Duration.to_nanos(interval) == 0) 1 else Duration.to_nanos(interval)
	},
}
