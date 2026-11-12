package client

// A small client SDK for the wire protocol. It speaks HTTP to a miraidb server
// (or to an in-process dispatcher in tests) and decodes the binary messages.
// The transport is injected so the same client runs over TCP, over a test
// double, or over any other framing a host provides.

import "core:fmt"
import "core:mem"
import "core:strings"

import engine "../engine"

Transport :: engine.Http_Transport

Client :: struct {
	transport: Transport,
	ctx:       rawptr,
	session:   string,
}

client_init :: proc(transport: Transport, ctx: rawptr) -> Client {
	return Client{transport = transport, ctx = ctx}
}

// client_authenticate sets the bearer token sent with every request.
client_authenticate :: proc(client: ^Client, token: string) {
	client.session = token
}

// client_request POSTs one wire message to /wire and returns the message body.
client_request :: proc(
	client: ^Client,
	message: []u8,
	alloc: mem.Allocator,
) -> ([]u8, engine.Error) {
	if client.transport == nil do return nil, engine.errf(.Invalid_Argument, "no transport")
	length := fmt.aprintf("%d", len(message))
	defer delete(length)
	head := strings.concatenate(
		{
			"POST /wire HTTP/1.1\r\nHost: miraidb\r\nContent-Type: application/octet-stream\r\nAccept-Encoding: zlib\r\nContent-Length: ",
			length,
			"\r\n",
		},
	)
	defer delete(head)
	authorization := ""
	if len(client.session) > 0 {
		authorization = strings.concatenate({"Authorization: Bearer ", client.session, "\r\n"})
	}
	defer delete(authorization)
	request := strings.concatenate({head, authorization, "\r\n", transmute(string)message})
	defer delete(request)
	raw, send_err := client.transport(client.ctx, transmute([]u8)request, alloc)
	if send_err.kind != .None do return nil, send_err
	response, parse_err := engine.http_parse_response(raw)
	if parse_err.kind != .None do return nil, parse_err
	if response.status != 200 {
		return nil, engine.errf(.Io, "the server answered HTTP %d", response.status)
	}
	if response.zlib {
		body, ok := engine.zlib_decompress(response.body, alloc)
		if !ok do return nil, engine.errf(.Invalid_Argument, "cannot inflate the response")
		return body, engine.ERROR_NONE
	}
	return response.body, engine.ERROR_NONE
}

@(private)
client_decode :: proc(
	body: []u8,
	alloc: mem.Allocator,
) -> (engine.Sql_Result, engine.Error) {
	switch engine.wire_message_kind(body) {
	case engine.WIRE_RESULT:
		return engine.wire_decode_result(body, alloc)
	case engine.WIRE_ERROR:
		if message, decoded := engine.wire_decode_error(body, alloc); decoded {
			return {}, message
		}
		return {}, engine.errf(.Internal, "malformed error message")
	case:
		return {}, engine.errf(.Internal, "unexpected message kind")
	}
}

// client_query runs one SQL statement.
client_query :: proc(
	client: ^Client,
	sql: string,
	alloc: mem.Allocator,
) -> (engine.Sql_Result, engine.Error) {
	message := engine.wire_encode_query(sql, nil)
	defer delete(message)
	body, request_err := client_request(client, message, alloc)
	if request_err.kind != .None do return {}, request_err
	return client_decode(body, alloc)
}

// client_call runs one reducer.
client_call :: proc(
	client: ^Client,
	reducer: string,
	args: []engine.Value,
	alloc: mem.Allocator,
) -> (engine.Sql_Result, engine.Error) {
	message := engine.wire_encode_call(0, reducer, args)
	defer delete(message)
	body, request_err := client_request(client, message, alloc)
	if request_err.kind != .None do return {}, request_err
	return client_decode(body, alloc)
}

// client_subscribe opens a subscription set and returns its id, the commit it
// was taken at and one row set per query.
client_subscribe :: proc(
	client: ^Client,
	sqls: []string,
	alloc: mem.Allocator,
) -> (id: u64, commit_seq: u64, snapshot: [][][]engine.Value, err: engine.Error) {
	message := engine.wire_encode_subscribe(sqls)
	defer delete(message)
	body, request_err := client_request(client, message, alloc)
	if request_err.kind != .None do return 0, 0, nil, request_err
	if engine.wire_message_kind(body) == engine.WIRE_ERROR {
		if message_err, decoded := engine.wire_decode_error(body, alloc); decoded {
			return 0, 0, nil, message_err
		}
		return 0, 0, nil, engine.errf(.Internal, "malformed error message")
	}
	return engine.wire_decode_snapshot(body, alloc)
}

// --- Subscription polling ---------------------------------------------------

// Poll_Delta is what changed between two row sets of the same query. The CLI
// uses it to print a live view without a stateful server-side subscription.
Poll_Delta :: struct {
	inserts: [][]engine.Value,
	deletes: [][]engine.Value,
}

poll_delta_destroy :: proc(delta: ^Poll_Delta) {
	for row in delta.inserts do engine.free_values(row)
	for row in delta.deletes do engine.free_values(row)
	delete(delta.inserts)
	delete(delta.deletes)
	delta^ = {}
}

// client_poll_diff compares two result sets by projected row and reports the
// rows that appeared and the ones that disappeared.
client_poll_diff :: proc(
	previous: [][]engine.Value,
	next: [][]engine.Value,
	alloc: mem.Allocator,
) -> Poll_Delta {
	previous_keys := make(map[string]bool, len(previous))
	defer delete(previous_keys)
	for row in previous do previous_keys[engine.Output_Key(row)] = true
	next_keys := make(map[string]bool, len(next))
	defer delete(next_keys)
	for row in next do next_keys[engine.Output_Key(row)] = true

	inserts := make([dynamic][]engine.Value, 0, len(next), alloc)
	deletes := make([dynamic][]engine.Value, 0, len(previous), alloc)
	for row in next {
		if engine.Output_Key(row) in previous_keys do continue
		append(&inserts, engine.Value_Row_Clone(row, alloc))
	}
	for row in previous {
		if engine.Output_Key(row) in next_keys do continue
		append(&deletes, engine.Value_Row_Clone(row, alloc))
	}
	return Poll_Delta{inserts = inserts[:], deletes = deletes[:]}
}
