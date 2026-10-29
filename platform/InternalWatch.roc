## Define the watch's host-ABI types.
InternalWatch :: [].{
	NativePath : [Utf8(Str), UnixBytes(List(U8)), WindowsU16s(List(U16))]

	# A zero poll interval means events from the operating system.
	ConfigToHost : {
		folders : List(NativePath),
		trees : List(NativePath),
		skip : List(Str),
		poll_nanos : U64,
	}

	ChangeFromHost : { path : NativePath, kind : [Created, Modified, Removed] }
}
