## Serve a folder, and tell open pages to reload when a file in it changes.
##
## These are the pieces `./joy dev` is made of: `main!` starts a server and
## carries on as the loop that watches files, while the server answers
## requests on threads of its own and sends events as `main!` publishes them.
##
##     roc build examples/dev-server.roc
##     ./examples/dev-server site/
##
## A page loads `/reload.js` to reload when something changes. Ctrl-C stops
## the loop, then the server.
app [main!] {
	http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	pf: platform "../platform/main.roc",
}

import pf.Duration
import pf.Events
import pf.OsStr
import pf.Path
import pf.Server
import pf.Signal
import pf.Sse
import pf.Stdout
import pf.Watch
import http.Request
import http.Response

main! : List(OsStr) => Try({}, _)
main! = |args| {
	folder =
		match args {
			[first, ..] => Path.from_os_str(first)
			[] => Path.utf8(".")
		}
	Signal.catch!([Interrupt])?

	events = Events.new!({})
	events.set_greeting!([hello(0)])
	server = start!(folder, events, 8000)?
	Stdout.line!("Serving ${Path.display(folder)} on http://localhost:${U16.to_str(server.port())}")?

	watch = Watch.start!({ trees: [folder], skip: [".git", "node_modules"] })?
	result = loop!(watch, events, 1)
	Server.stop!(server)
	result
}

## Take 8000, or the next free port, as `./joy dev` does.
start! = |folder, events, port| {
	match Server.start!({ port, roots: [{ name: "site", path: folder, cache: Revalidate }] }, |request| route!(events, request)) {
		Err(ServerErr(AddrInUse)) if port < 8100 => start!(folder, events, port + 1)
		other => other
	}
}

loop! : Watch, Events, U64 => Try({}, _)
loop! = |watch, events, build|
	match watch.next!({ timeout: Duration.seconds(1) }) {
		Ok([]) => loop!(watch, events, build)
		Ok(changes) => {
			# A page that connects from now on learns the new build from its
			# greeting, and the open ones are told to reload.
			events.set_greeting!([hello(build)])
			pages = events.publish!(Sse.Event.named("reload", [U64.to_str(build)]))
			Stdout.line!("${changes.len().to_str()} changed, ${pages.to_str()} pages told to reload")?
			loop!(watch, events, build + 1)
		}
		Err(Interrupted) => {
			# Acknowledge Ctrl-C, or every effect after it is interrupted too.
			_ = Signal.poll!()
			Stdout.line!("Stopped")?
			Ok({})
		}
		Err(err) => Err(err)
	}

hello : U64 -> Sse.Event
hello = |build| Sse.Event.named("hello", [U64.to_str(build)])

route! = |events, request| {
	path =
		match Request.uri(request).split_first("?") {
			Ok({ before, .. }) => before
			Err(NotFound) => Request.uri(request)
		}
	if path == "/events" {
		Ok(Server.stream(events, []))
	} else if path == "/reload.js" {
		Ok(Server.respond(script(reload_js)))
	} else if has_extension(path) {
		Ok(Server.file("site", path))
	} else {
		# A path without an extension is a page, so a single-page app that
		# changes the URL survives a refresh.
		Ok(Server.file("site", "index.html"))
	}
}

has_extension = |path|
	match Str.split_last(path, "/") {
		Ok({ after, .. }) => Str.contains(after, ".")
		Err(_) => Str.contains(path, ".")
	}

script = |source|
	Response.from_status(200)
		.with_body(Str.to_utf8(source))
		.add_header("Content-Type", "text/javascript; charset=utf-8")
		.add_header("Cache-Control", "no-cache")

reload_js =
	\\new EventSource("/events").addEventListener("reload", () => location.reload());
