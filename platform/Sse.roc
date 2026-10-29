## Server-sent events, framed for an event stream.
##
## An [Event] is one complete frame. [Events.publish!] sends it to every open
## stream, and [Server.stream] answers a request with a stream.
Sse :: [].{
	EventId := [AbsentEventId, ClearEventId, SetEventId(Str)]

	Retry := [NoRetry, RetryAfter(U64)]

	EventOptions := {
		id : EventId,
		retry : Retry,
	}

	default_event_options : EventOptions
	default_event_options = { id: AbsentEventId, retry: NoRetry }

	## Validate an SSE event ID. IDs become `Last-Event-ID` request header
	## values on reconnect, so NUL and line endings are rejected rather than
	## normalized.
	event_id : Str -> Try(EventId, [InvalidEventId])
	event_id = |value|
		if Str.contains(value, "\r") or Str.contains(value, "\n") or List.any(Str.to_utf8(value), |byte| byte == 0) {
			Err(InvalidEventId)
		} else {
			Ok(SetEventId(value))
		}

	## Emit an empty `id:` field, clearing the client's retained reconnect ID.
	clear_event_id : EventId
	clear_event_id = ClearEventId

	## Ask the client to use a new reconnect delay, in milliseconds.
	retry_after : U64 -> Retry
	retry_after = |milliseconds| RetryAfter(milliseconds)

	Event := [Event(List(U8))].{

		## Return the canonical framed bytes for a finite response. Applications
		## normally pass events to an SSE response helper instead of inspecting
		## this representation directly.
		to_bytes : Event -> List(U8)
		to_bytes = |Event(bytes)| bytes

		## Construct a named SSE event containing one keyed data value. The common
		## single-line path creates the complete frame once, and multiline values fall
		## back to canonical repeated keyed fields.
		keyed : Str, Str, Str -> Event
		keyed = |name, key, value| {
			safe_name =
				if Str.contains(name, "\r") or Str.contains(name, "\n") {
					Str.join_with(Str.split_on(Str.join_with(Str.split_on(name, "\r"), ""), "\n"), "")
				} else {
					name
				}

			if Str.contains(value, "\r") or Str.contains(value, "\n") {
				lf = Str.join_with(Str.split_on(value, "\r\n"), "\n")
				normalized = Str.join_with(Str.split_on(lf, "\r"), "\n")
				fields = Str.split_on(normalized, "\n").map(|line| "${key} ${line}")
				named(safe_name, fields)
			} else {
				frame = Str.with_capacity(
					17 + Str.count_utf8_bytes(safe_name) + Str.count_utf8_bytes(key) + Str.count_utf8_bytes(value),
				)
					.concat("event: ")
					.concat(safe_name)
					.concat("\ndata: ")
					.concat(key)
					.concat(" ")
					.concat(value)
					.concat("\n\n")
				Event(Str.to_utf8(frame))
			}
		}

		## Construct one named SSE event from already-keyed data fields. Event
		## names have line endings removed so they cannot create a second SSE
		## field. Every logical line in a data field is emitted as its own
		## `data:` line.
		named : Str, List(Str) -> Event
		named = |name, values| named_with(name, values, default_event_options)

		## Construct a named event with optional reconnect ID and retry metadata.
		## The ID is already validated by [`event_id`](#Sse.event_id), and all data
		## values remain canonical `data:` fields.
		named_with : Str, List(Str), EventOptions -> Event
		named_with = |name, values, options| {
			safe_name = Str.join_with(Str.split_on(Str.join_with(Str.split_on(name, "\r"), ""), "\n"), "")
			id_fields =
				match options.id {
					AbsentEventId => []
					ClearEventId => ["id:"]
					SetEventId(value) => ["id: ${value}"]
				}
			retry_fields =
				match options.retry {
					NoRetry => []
					RetryAfter(milliseconds) => ["retry: ${U64.to_str(milliseconds)}"]
				}
			fields = values.map(
				|value| {
					lf = Str.join_with(Str.split_on(value, "\r\n"), "\n")
					normalized = Str.join_with(Str.split_on(lf, "\r"), "\n")
					lines = Str.split_on(normalized, "\n").map(|line| "data: ${line}")
					Str.join_with(lines, "\n")
				},
			)
			lines = List.concat(List.concat(["event: ${safe_name}"], id_fields), List.concat(retry_fields, fields))
			Event(Str.to_utf8("${Str.join_with(lines, "\n")}\n\n"))
		}

		## Construct one SSE data event. Embedded CR, LF, and CRLF line endings
		## are normalized and emitted as one `data:` field per logical line.
		data : Str -> Event
		data = |value| {
			if Bool.not(Str.contains(value, "\r")) and Bool.not(Str.contains(value, "\n")) {
				frame = Str.with_capacity(8 + Str.count_utf8_bytes(value))
					.concat("data: ")
					.concat(value)
					.concat("\n\n")
				return Event(Str.to_utf8(frame))
			}
			lf = Str.join_with(Str.split_on(value, "\r\n"), "\n")
			normalized = Str.join_with(Str.split_on(lf, "\r"), "\n")
			fields = Str.split_on(normalized, "\n").map(|line| "data: ${line}")
			Event(Str.to_utf8("${Str.join_with(fields, "\n")}\n\n"))
		}
	}
}
