import Events
import Host
import InternalHttp
import InternalServer
import IOErr
import Path
import http.Header
import http.Request
import http.Response

## Serve HTTP from inside a running program.
##
## [start!] binds a port, starts serving on the host's threads and returns at
## once, so `main!` carries on beside the server: watching, building, and
## publishing to [Events]. The server stops when [stop!] is called, when
## `main!` returns, or when the process ends.
##
## ```roc
## server = Server.start!(
## 	{ port: 0, roots: [{ name: "site", path: Path.utf8("public"), cache: Revalidate }] },
## 	|request| Ok(Server.file("site", Str.drop_prefix(request.uri(), "/"))),
## )?
## Stdout.line!("Serving on http://localhost:${U16.to_str(server.port())}")?
## ```
##
## The handler runs on one of the host's threads, beside `main!` and beside
## other requests. It sees only what it captured when the server started, so
## a value that changes while the program runs reaches it through a file, an
## [Events] greeting, or a restart.
##
## A handler that returns `Err` is logged to stderr and answered with a 500.
Server :: { id : U64, port : U16 }.{

	## How long a cache may keep a file response: `NoStore`, `Revalidate`
	## (`Cache-Control: no-cache`), or kept for a number of seconds by private
	## or shared caches.
	Cache : [NoStore, Revalidate, PrivateFor(U32), PublicFor(U32)]

	## A folder that file responses come from, declared when the server
	## starts. Files are opened one path component at a time without following
	## links, and no path component may start with a dot.
	Root : { name : Str, path : Path, cache : Cache }

	## A path the host answers from roots by itself, before any handler runs, so
	## a file never waits behind requests the handlers are busy with.
	##
	## A `GET` or `HEAD` below `path` gets the file from the first of `roots` that
	## has it, by its path below `path`. `miss` says what happens otherwise:
	## `NotFound` owns the path, so no request below it reaches a handler, with a
	## 404 for a missing file and a 405 for any other method. `AskHandler` passes
	## those requests, and paths that name a folder, on to the handler.
	## `download` answers each file as a download, named after the last part of
	## its path.
	FileRoute : { path : Str, roots : List(Str), miss : [NotFound, AskHandler], download : Bool }

	## Where the server listens, which folders it serves files from, what the
	## host answers from them by itself, how large a request body may be, and
	## how many handlers may run at once.
	##
	## Port 0 asks the system for a free port, which [port] then reports.
	## `"localhost"` listens on 127.0.0.1.
	##
	## A request with a larger body than `max_body_bytes` is answered with a
	## 413. A client gets 30 seconds to send a request's headers, and 60
	## seconds between two pieces of its body, so a slow upload that keeps
	## sending is never cut off, and one that stalls is answered with a 408.
	## The server keeps at most 512 connections open, and further ones wait
	## until one closes.
	Config := {
		host : Str ?? "localhost",
		port : U16 ?? 0,
		roots : List(Root) ?? [],
		file_routes : List(FileRoute) ?? [],
		max_body_bytes : U64 ?? 16_777_216,
		handlers : U16 ?? 4,
	}

	## What a handler answers a request with.
	Reply := [
		Respond(Response),
		File({ root : Str, path : Str, cache : [Inherit, Override(Cache)], headers : List(Header) }),
		Stream({ events : Events, headers : List(Header) }),
	]

	## Answer with a response built in Roc. The host sets `Content-Length`
	## from the body and leaves out a handler's `Content-Length` and
	## `Transfer-Encoding`.
	respond : Response -> Reply
	respond = |response| Respond(response)

	## Answer with a file from a declared root, by its path below the root,
	## under the root's cache policy. A file that does not exist, or a path
	## that is not allowed, is a 404. Only `GET` and `HEAD` are answered.
	##
	## The host streams the file without its bytes passing through Roc, and
	## answers conditional and range requests.
	file : Str, Str -> Reply
	file = |root, path| File({ root, path, cache: Inherit, headers: [] })

	## Like [file], with a cache policy of its own and extra headers.
	##
	## A header replaces the host's header of the same name, such as the
	## file's `Content-Type`, and more of one name are all sent. The host keeps
	## its own `Content-Length`, `Transfer-Encoding`, `Content-Range` and `ETag`,
	## since they say which bytes of which version of the file are sent, and
	## leaves out a handler's. The headers go only with a file that is sent
	## or a 304. A 404, a 405 or a range the file lacks is the host's answer
	## alone, so CORS headers set here are not on it.
	file_with : { root : Str, path : Str, cache : Cache, headers : List(Header) } -> Reply
	file_with = |{ root, path, cache, headers }| File({ root, path, cache: Override(cache), headers })

	## Answer with an event stream that sends the greeting of `events` and then
	## every event published to it. The extra headers are sent along, for CORS
	## say, with `Content-Type: text/event-stream` and
	## `Cache-Control: no-cache`, which a header of the same name replaces.
	stream : Events, List(Header) -> Reply
	stream = |events, headers| Stream({ events, headers })

	## Bind the port and start serving. Returns once the server listens.
	##
	## `ServerErr(AddrInUse)` means the port is taken, so a caller can try the
	## next one.
	start! : Config, (Request => Try(Reply, _err)) => Try(Server, [ServerErr(IOErr), BadRoot(Str, IOErr), BadConfig(Str)])
	start! = |config, handler!| {
		respond! = |raw_request| {
			request = InternalHttp.from_host_request(raw_request)
			match handler!(request) {
				Ok(reply) => to_host_reply(reply)
				Err(err) => Failed("${Request.method_str(request)} ${Request.uri(request)}: ${Str.inspect(err)}")
			}
		}
		match Host.server_start!(to_host_config(config), InternalServer.handler(respond!)) {
			Ok({ id, port }) => Ok({ id, port })
			Err(ServerErr(err)) => Err(ServerErr(err))
			Err(BadRoot(name, err)) => Err(BadRoot(name, err))
			Err(BadConfig(problem)) => Err(BadConfig(problem))
		}
	}

	## The port the server listens on.
	port : Server -> U16
	port = |server| server.port

	## Stop accepting connections, close the open ones, event streams
	## included, and wait for the server to finish. Handlers still running
	## finish on their own. Stopping a stopped server does nothing.
	stop! : Server => {}
	stop! = |server| Host.server_stop!(server.id)

	to_inspect : Server -> Str
	to_inspect = |server| "Server(port ${U16.to_str(server.port)})"
}

to_host_config : Server.Config -> InternalServer.ConfigToHost
to_host_config = |config| {
	host: config.host,
	port: config.port,
	roots: config.roots.map(
		|root| {
			(cache, max_age_seconds) = cache_to_host(root.cache)
			{ name: root.name, path: Path.to_raw(root.path), cache, max_age_seconds }
		},
	),
	file_routes: config.file_routes.map(
		|route| { path: route.path, roots: route.roots, asks_handler: route.miss == AskHandler, download: route.download },
	),
	max_body_bytes: config.max_body_bytes,
	handlers: config.handlers,
}

cache_to_host : Server.Cache -> (U8, U32)
cache_to_host = |cache|
	match cache {
		NoStore => (0, 0)
		Revalidate => (1, 0)
		PrivateFor(seconds) => (2, seconds)
		PublicFor(seconds) => (3, seconds)
	}

to_host_reply : Server.Reply -> InternalServer.ReplyToHost
to_host_reply = |reply|
	match reply {
		Respond(response) => Respond(InternalHttp.to_host_response(response))
		File({ root, path, cache, headers }) => {
			(tag, max_age_seconds) =
				match cache {
					Inherit => (255, 0)
					Override(policy) => cache_to_host(policy)
				}
			File({ root, path, cache: tag, max_age_seconds, headers: InternalHttp.to_host_headers(headers) })
		}
		Stream({ events, headers }) => Stream({ events: Events.to_host(events), headers: InternalHttp.to_host_headers(headers) })
	}
