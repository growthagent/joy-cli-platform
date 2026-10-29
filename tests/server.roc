## Start a server from `main!` and talk to it with the platform's own HTTP
## client: files from a declared root, responses built in Roc, request bodies,
## a handler error, event streams fed from `Events`, a taken port, and stop.
app [main!] {
	http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	pf: platform "../platform/main.roc",
}

import pf.Duration
import pf.Env
import pf.Events
import pf.Http
import pf.OsStr
import pf.Path
import pf.Server
import pf.Sse
import pf.Stdout
import http.Request
import http.Response

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	Env.with_temp_dir!(|site| serve!(site))?
	Stdout.line!("Server checks passed")
}

serve! = |site| {
	Path.create_dir!(Path.join(site, "css"))?
	Path.write_utf8!(Path.join(site, "index.html"), "<h1>Shelf</h1>")?
	Path.write_utf8!(Path.join(site, "css/site.css"), "h1 { color: teal }")?
	Path.write_utf8!(Path.join(site, ".env"), "SECRET=1")?

	events = Events.new!({})
	events.set_greeting!([Sse.Event.named("hello", ["1"])])

	server = Server.start!(
		{ roots: [{ name: "site", path: site, cache: Revalidate }] },
		|request| route!(events, request),
	)?
	base = "http://localhost:${U16.to_str(server.port())}"
	Stdout.line!("listening on a port of its own: ${Str.inspect(server.port() > 0)}")?

	index = get!("${base}/")?
	expect Response.status(index) == 200
	expect Str.from_utf8(Response.body(index)) == Ok("<h1>Shelf</h1>")
	expect header(index, "cache-control") == Ok("no-cache")
	expect header(index, "content-type") == Ok("text/html; charset=utf-8")
	Stdout.line!("GET / is the index file")?

	css = get!("${base}/css/site.css?joy=2")?
	expect Str.from_utf8(Response.body(css)) == Ok("h1 { color: teal }")
	expect header(css, "content-type") == Ok("text/css; charset=utf-8")
	Stdout.line!("a query is not part of a file path")?

	missing = get!("${base}/missing.css")?
	dotfile = get!("${base}/.env")?
	parent = get!("${base}/../server.roc")?
	expect [missing, dotfile, parent].map(Response.status) == [404, 404, 404]
	Stdout.line!("missing files, dotfiles and parents are 404")?

	hello = get!("${base}/api/hello")?
	expect Str.from_utf8(Response.body(hello)) == Ok("hello from Roc")
	expect header(hello, "x-joy") == Ok("1")
	Stdout.line!("a handler answers with a response built in Roc")?

	echo = Http.send!(Request.from_method(POST).with_uri("${base}/api/echo").with_body(Str.to_utf8("a body")), {})?
	expect Str.from_utf8(Response.body(echo)) == Ok("POST /api/echo a body")
	Stdout.line!("a handler sees the method, the URI and the body")?

	failed = get!("${base}/api/fail")?
	expect Response.status(failed) == 500
	Stdout.line!("a handler that fails is a 500")?

	stream = Http.send_streaming!(Request.from_method(GET).with_uri("${base}/events"), { idle_timeout: After(Duration.seconds(5)) })?
	expect stream.status() == 200
	expect stream_header(stream, "content-type") == Ok("text/event-stream")
	expect stream_header(stream, "access-control-allow-origin") == Ok("*")
	greeting = next_text!(stream)?
	expect greeting == "event: hello\ndata: 1\n\n"
	Stdout.line!("an event stream starts with the greeting")?

	open_streams = events.streams!()
	expect open_streams == 1
	reached = events.publish!(Sse.Event.named("reload", ["catalog"]))
	expect reached == 1
	reload = next_text!(stream)?
	expect reload == "event: reload\ndata: catalog\n\n"
	Stdout.line!("a published event reaches the open stream")?

	# A port that is taken is reported as such, so a caller can try another.
	match Server.start!({ port: server.port() }, |_| Ok(Server.respond(Response.from_status(204)))) {
		Err(ServerErr(AddrInUse)) => Stdout.line!("a taken port is AddrInUse")?
		other => {
			return Err(ExpectedAddrInUse(Str.inspect(other)))
		}
	}

	match Server.start!({ roots: [{ name: "gone", path: Path.join(site, "absent"), cache: NoStore }] }, |_| Ok(Server.respond(Response.from_status(204)))) {
		Err(BadRoot("gone", NotFound)) => Stdout.line!("a missing root is BadRoot")?
		other => {
			return Err(ExpectedBadRoot(Str.inspect(other)))
		}
	}

	Server.stop!(server)
	Server.stop!(server)
	match Http.send!(Request.from_method(GET).with_uri("${base}/"), {}) {
		Err(HttpErr(_)) => Stdout.line!("a stopped server answers nothing")?
		other => {
			return Err(ExpectedNoAnswer(Str.inspect(other)))
		}
	}
	Ok({})
}

route! = |events, request| {
	path =
		match Request.uri(request).split_first("?") {
			Ok({ before, .. }) => before
			Err(NotFound) => Request.uri(request)
		}
	match (Request.method(request), path) {
		(GET, "/") => Ok(Server.file("site", "index.html"))
		(GET, "/api/hello") => Ok(Server.respond(Response.from_status(200).with_body(Str.to_utf8("hello from Roc")).add_header("X-Joy", "1")))
		(POST, "/api/echo") => {
			body = Str.from_utf8(Request.body(request)) ?? "?"
			Ok(Server.respond(Response.from_status(200).with_body(Str.to_utf8("POST ${path} ${body}"))))
		}
		(GET, "/api/fail") => Err(DeliberateFailure)
		(GET, "/events") => Ok(Server.stream(events, [{ name: "Access-Control-Allow-Origin", value: "*" }]))
		_ => Ok(Server.file("site", Request.uri(request)))
	}
}

get! = |url| Http.send!(Request.from_method(GET).with_uri(url), {})

header = |response, name|
	match Response.headers(response).find_first(|h| h.name.caseless_ascii_equals(name)) {
		Ok(found) => Ok(found.value)
		Err(_) => Err(Missing(name))
	}

stream_header = |response, name|
	match response.headers().find_first(|h| h.name.caseless_ascii_equals(name)) {
		Ok(found) => Ok(found.value)
		Err(_) => Err(Missing(name))
	}

next_text! = |response|
	match Stream.next!(response.chunks()) {
		One({ item: Ok(chunk), .. }) => Str.from_utf8(chunk)
		One({ item: Err(err), .. }) => Err(StreamFailed(err))
		_ => Err(StreamEnded)
	}
