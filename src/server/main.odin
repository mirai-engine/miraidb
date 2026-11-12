// miraidb-server: the HTTP front end. It owns the socket loop; all protocol
// logic lives in the engine (http.odin, wire.odin).
package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"

import db "../engine"

USAGE :: `miraidb-server - HTTP front end for a miraidb database

Usage:
  miraidb-server <database> [--port=8080] [--any]

Endpoints:
  POST /call         wire message: reducer call with a request id
  POST /query        wire message: one-off query
  POST /subscribe    wire message: subscription set
  POST /unsubscribe  wire message: drop a subscription
  POST /wire         any of the above, dispatched by the message kind
  GET  /health       liveness probe

Bodies are the binary messages described in src/engine/wire.odin.
`

main :: proc() {
	path := ""
	port := 8080
	any_interface := false
	for arg in os.args[1:] {
		switch {
		case strings.has_prefix(arg, "--port="):
			parsed, ok := strconv.parse_int(arg[len("--port="):])
			if !ok {
				fmt.eprintln("miraidb-server: --port needs a number")
				os.exit(2)
			}
			port = int(parsed)
		case arg == "--any":
			any_interface = true
		case strings.has_prefix(arg, "-"):
			fmt.eprintfln("miraidb-server: unknown option %s", arg)
			os.exit(2)
		case:
			path = arg
		}
	}
	if len(path) == 0 {
		fmt.eprintln(USAGE)
		os.exit(2)
	}
	store, err := db.store_open(path, {persistent = true, create = true, durable = true})
	if !db.error_ok(err) {
		fmt.eprintfln("miraidb-server: %s: %s", db.error_kind_name(err.kind), err.message)
		os.exit(1)
	}
	defer db.store_close(store)
	host := db.host_init(store)
	defer db.host_destroy(host)

	address := any_interface ? net.IP4_Any : net.IP4_Loopback
	endpoint := net.Endpoint{address = address, port = port}
	listener, listen_err := net.listen_tcp(endpoint)
	if listen_err != nil {
		fmt.eprintfln("miraidb-server: cannot listen on port %d: %v", port, listen_err)
		os.exit(1)
	}
	defer net.close(listener)
	fmt.printfln("miraidb-server listening on port %d (database %s)", port, path)
	client_counter := u64(0)
	for {
		client, _, accept_err := net.accept_tcp(listener)
		if accept_err != nil do continue
		client_counter += 1
		serve(host, client, client_counter)
	}
}

@(private)
serve :: proc(host: ^db.Host, client: net.TCP_Socket, owner: u64) {
	defer net.close(client)
	if !db.host_client_connect(host, owner) {
		reject := transmute([]u8)string("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
		_, _ = net.send(client, reject)
		return
	}
	defer db.host_client_disconnect(host, owner)
	buffer: [64 * 1024]u8
	n, recv_err := net.recv(client, buffer[:])
	if recv_err != nil || n <= 0 do return
	if token, has_token := db.http_bearer_token(buffer[:n]); has_token {
		if identity, valid := db.host_authenticate(host, token); valid {
			db.store_set_identity(host.store, identity)
		}
	}
	if db.pg_is_startup(buffer[:n]) {
		serve_postgres(host, client)
		return
	}
	if db.ws_is_upgrade(buffer[:n]) {
		if handshake, ok := db.ws_handshake(buffer[:n]); ok {
			_, _ = net.send(client, handshake)
			delete(handshake)
			serve_frames(host, client, owner)
			return
		}
	}
	// A request may arrive in more than one segment. Reading once and parsing
	// would reject a body that has not landed yet, so the loop keeps reading
	// while the parser says the message is incomplete.
	request: db.Http_Request
	parse_err: db.Error
	used := 0
	for {
		request, used, parse_err = db.http_parse_request_within(
			buffer[:n],
			host.max_header_bytes,
			host.max_request_bytes,
		)
		if db.error_ok(parse_err) do break
		if parse_err.kind != .Incomplete {
			status := 400
			if parse_err.kind == .Quota_Exceeded do status = 413
			body := text_bytes("bad request")
			response := db.http_response(status, "text/plain", body)
			delete(body)
			_, _ = net.send(client, response)
			delete(response)
			return
		}
		if n >= len(buffer) do return
		read, more_err := net.recv(client, buffer[n:])
		if more_err != nil || read <= 0 do return
		n += read
	}
	_ = used
	response := db.http_handle(host, request)
	_, _ = net.send(client, response)
	delete(response)
}

// serve_frames runs the WebSocket loop: each binary or text frame carries one
// wire message and the answer goes back in one binary frame.
// serve_postgres answers the startup and then handles simple-query messages.
@(private)
serve_postgres :: proc(host: ^db.Host, client: net.TCP_Socket) {
	hello := db.pg_authentication_ok()
	_, _ = net.send(client, hello)
	delete(hello)
	version := db.pg_parameter_status("server_version", "14.0")
	_, _ = net.send(client, version)
	delete(version)
	ready := db.pg_ready_for_query('I')
	_, _ = net.send(client, ready)
	delete(ready)
	session := db.pg_session_init()
	defer db.pg_session_destroy(session)
	buffer: [64 * 1024]u8
	for {
		n, recv_err := net.recv(client, buffer[:])
		if recv_err != nil || n <= 0 do return
		response, close := db.pg_handle_session_message(host, session, buffer[:n])
		if len(response) > 0 {
			_, _ = net.send(client, response)
			delete(response)
		}
		if close do return
	}
}

// policy_send queues `bytes` in the client's outbox and writes them. When the
// outbox budget is exceeded the message is discarded and the connection is
// closed on the next write, which is the drop policy.
@(private)
policy_send :: proc(host: ^db.Host, client: net.TCP_Socket, owner: u64, bytes: []u8) -> bool {
	if owner == 0 {
		_, _ = net.send(client, bytes)
		return true
	}
	if !db.host_client_enqueue(host, owner, u64(len(bytes))) do return false
	_, _ = net.send(client, bytes)
	db.host_client_dequeue(host, owner, u64(len(bytes)))
	return !db.host_client_should_drop(host, owner)
}

@(private)
serve_frames :: proc(host: ^db.Host, client: net.TCP_Socket, owner: u64) {
	defer _ = db.host_drop_owned(host, owner)
	buffer: [64 * 1024]u8
	for {
		n, recv_err := net.recv(client, buffer[:])
		if recv_err != nil || n <= 0 do return
		payload, _, opcode, frame_err := db.ws_read_frame_within(buffer[:n], host.max_frame_bytes)
		if !db.error_ok(frame_err) do return
		if opcode == 8 {
			delete(payload)
			return
		}
		if opcode == 1 || opcode == 2 {
			response := db.wire_request_owned(host, payload, owner)
			framed := db.ws_frame(response)
			sent := policy_send(host, client, owner, framed)
			delete(framed)
			delete(response)
			if !sent do return
		}
		delete(payload)
	}
}

@(private)
text_bytes :: proc(text: string) -> []u8 {
	out := make([]u8, len(text))
	copy(out, text)
	return out
}
