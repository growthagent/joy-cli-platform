import InternalHttp
import IOErr

## Define the server's host-ABI types. These records map directly to the
## generated Rust glue types.
InternalServer :: [].{
	NativePath : [Utf8(Str), UnixBytes(List(U8)), WindowsU16s(List(U16))]

	# Cache policies cross as a tag and an age, the encoding the file server
	# reads: 0 no-store, 1 revalidate, 2 private, 3 public, 255 the root's own.
	RootToHost : {
		name : Str,
		path : NativePath,
		cache : U8,
		max_age_seconds : U32,
	}

	ConfigToHost : {
		host : Str,
		port : U16,
		roots : List(RootToHost),
		max_body_bytes : U64,
		handlers : U16,
	}

	Started : { id : U64, port : U16 }

	StartErr : [ServerErr(IOErr), BadRoot(Str, IOErr), BadConfig(Str)]

	ReplyToHost : [
		Respond(InternalHttp.ResponseToAndFromHost),
		File({ root : Str, path : Str, cache : U8, max_age_seconds : U32, headers : List(InternalHttp.HostHeaderTuple) }),
		Stream({ events : U64, headers : List(InternalHttp.HostHeaderTuple) }),
		Failed(Str),
	]

	## A request handler, kept by the host for as long as its server runs.
	Handler := [Handler(Box(InternalHttp.RequestToAndFromHost => ReplyToHost))]

	handler : (InternalHttp.RequestToAndFromHost => ReplyToHost) -> Handler
	handler = |respond!| Handler(Box.box(respond!))

	## Platform ABI operation, not an application API.
	respond_for_host! : Handler, InternalHttp.RequestToAndFromHost => ReplyToHost
	respond_for_host! = |Handler(boxed), request| (Box.unbox(boxed))(request)
}
