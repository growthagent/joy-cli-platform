import Host
import Sse

## A broadcast that the program publishes to and event streams read from.
##
## A handler answers a request with [Server.stream], and from then on the
## stream sends every event published here. A stream waits until something is
## published, rather than waking on a timer to check.
##
## Each stream starts with the greeting, the events last given to
## [set_greeting!], and then gets every event published after it opened.
## Setting the greeting and opening a stream do not race: a stream that opens
## while an event is published gets either the old greeting and the event, or
## the new greeting alone.
##
## The buffer is bounded. A stream that falls more than `capacity` events
## behind is closed, so the page reconnects and starts again from the greeting.
##
## An `Events` lives until the program ends.
Events :: { id : U64 }.{

	## How many events a stream may fall behind before it is closed.
	Options := { capacity : U64 ?? 256 }

	## Make a broadcast with no streams and an empty greeting.
	##
	## ```roc
	## events = Events.new!({})
	## ```
	new! : Options => Events
	new! = |options| { id: Host.events_new!(if (options.capacity == 0) 1 else options.capacity) }

	## Send an event to every open stream, and return how many it reached.
	publish! : Events, Sse.Event => U64
	publish! = |events, event| Host.events_publish!(events.id, Sse.Event.to_bytes(event))

	## Replace the events each stream starts with. Streams already open are
	## not sent the new greeting.
	set_greeting! : Events, List(Sse.Event) => {}
	set_greeting! = |events, greeting|
		Host.events_set_greeting!(events.id, List.join(greeting.map(Sse.Event.to_bytes)))

	## How many streams are open.
	streams! : Events => U64
	streams! = |events| Host.events_streams!(events.id)

	## Platform ABI operation, not an application API.
	to_host : Events -> U64
	to_host = |events| events.id

	to_inspect : Events -> Str
	to_inspect = |events| "Events(${U64.to_str(events.id)})"
}
