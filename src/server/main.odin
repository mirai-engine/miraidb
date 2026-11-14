// miraidb-server: the HTTP front end. It owns the socket loop; all protocol
// logic lives in the engine (http.odin, wire.odin).
package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"

import db "../engine"

USAGE :: `miraidb-server - HTTP front end for a miraidb database

Usage:
  miraidb-server <database> [--port=8080] [--any] [--allow-host]

The three statements that reach outside the database are refused to clients
unless --allow-host is given: ATTACH reads a file path, LOAD EXTENSION runs host
code, and VACUUM INTO writes a file. A client can name any path or module, so the
default is to believe none of them.

Each connection is served on its own thread, so a subscription that stays open
does not stop another client from connecting. Statements are still run one at a
time (the store carries the caller's identity as it executes), and a statement's
result is written back to the socket it belongs to under that socket's lock.

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
	allow_host := false
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
		case arg == "--allow-host":
			allow_host = true
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
	// The default refuses the statements that reach outside the database; a
	// deployment that trusts every client it serves says so on the command line.
	db.store_set_host_access(store, allow_host)
	host := db.host_init(store)
	defer db.host_destroy(host)
	server := Server{host = host}
	server.connections = make(map[u64]^Connection)
	defer delete(server.connections)
	host.on_update = server_on_update
	host.on_update_ctx = &server

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
		connection := new(Connection)
		connection^ = Connection{port = &server, socket = client, owner = client_counter}
		// The thread owns the connection record once it starts: it registers the
		// socket, serves it until the peer leaves, and frees the record.
		_ = thread.create_and_start_with_data(connection, serve_connection, {})
	}
}

// Server is what every connection thread shares: the host, the one statement
// lock (the store carries one identity while a statement runs) and the registry
// that routes a delta to the socket the subscriber is reading.
Server :: struct {
	host:        ^db.Host,
	statements:  sync.Mutex,
	connections: map[u64]^Connection,
}

// Connection is one accepted socket. send_mutex serialises writes: the thread
// that serves the requests and the thread that commits a change another
// subscription is watching both write to it.
Connection :: struct {
	port:       ^Server,
	socket:     net.TCP_Socket,
	owner:      u64,
	send_mutex: sync.Mutex,
}

@(private)
serve_connection :: proc(data: rawptr) {
	connection := (^Connection)(data)
	defer free(connection)
	serve(connection)
}

// server_register records a connection so a delta can find its socket. The map
// is guarded by the statement lock: registrations are few and the same lock
// already serialises the registry walk in a commit.
@(private)
server_register :: proc(server: ^Server, connection: ^Connection) {
	sync.mutex_lock(&server.statements)
	server.connections[connection.owner] = connection
	sync.mutex_unlock(&server.statements)
}

@(private)
server_forget :: proc(server: ^Server, connection: ^Connection) {
	delete_key(&server.connections, connection.owner)
}

// server_on_update is called from the thread that ran the commit. It finds the
// connection that owns the subscription and writes one delta frame into it.
@(private)
server_on_update :: proc(ctx: rawptr, update: ^db.Subscription_Update) {
	server := (^Server)(ctx)
	if server == nil do return
	owner := db.host_subscription_owner(server.host, update.subscription_id)
	if owner == 0 do return
	connection, exists := server.connections[owner]
	if !exists do return
	message := db.wire_encode_delta(update)
	defer delete(message)
	framed := db.ws_frame(message)
	defer delete(framed)
	_ = policy_send(connection, framed)
}

// send writes one message to the socket under the connection's lock.
@(private)
send :: proc(connection: ^Connection, bytes: []u8) -> bool {
	sync.mutex_lock(&connection.send_mutex)
	defer sync.mutex_unlock(&connection.send_mutex)
	_, err := net.send(connection.socket, bytes)
	return err == nil
}

@(private)
serve :: proc(connection: ^Connection) {
	host := connection.port.host
	client := connection.socket
	owner := connection.owner
	defer net.close(client)
	if !db.host_client_connect(host, owner) {
		reject := transmute([]u8)string("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
		_ = send(connection, reject)
		return
	}
	server_register(connection.port, connection)
	defer server_forget(connection.port, connection)
	// Dropping the subscriptions touches the list a commit walks, so it waits for
	// the statement in flight, exactly like a request does.
	defer {
		sync.mutex_lock(&connection.port.statements)
		db.host_client_disconnect(host, owner)
		sync.mutex_unlock(&connection.port.statements)
	}
	buffer: [64 * 1024]u8
	n, recv_err := net.recv(client, buffer[:])
	if recv_err != nil || n <= 0 do return
	if db.pg_is_startup(buffer[:n]) {
		serve_postgres(connection)
		return
	}
	if db.ws_is_upgrade(buffer[:n]) {
		if handshake, ok := db.ws_handshake(buffer[:n]); ok {
			defer delete(handshake)
			_ = send(connection, handshake)
			serve_frames(connection)
			return
		}
	}
	// The token decides the identity the request runs under, and the store
	// carries it while the statement executes: both happen inside the statement
	// lock so two clients never see each other's identity.
	if token, has_token := db.http_bearer_token(buffer[:n]); has_token {
		sync.mutex_lock(&connection.port.statements)
		if identity, valid := db.host_authenticate(host, token); valid {
			db.store_set_identity(host.store, identity)
		}
		sync.mutex_unlock(&connection.port.statements)
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
			_ = send(connection, response)
			delete(response)
			return
		}
		if n >= len(buffer) do return
		read, more_err := net.recv(client, buffer[n:])
		if more_err != nil || read <= 0 do return
		n += read
	}
	_ = used
	sync.mutex_lock(&connection.port.statements)
	response := db.http_handle(host, request)
	sync.mutex_unlock(&connection.port.statements)
	_ = send(connection, response)
	delete(response)
}

// serve_frames runs the WebSocket loop: each binary or text frame carries one
// wire message and the answer goes back in one binary frame.
// serve_postgres answers the startup and then handles simple-query messages.
@(private)
serve_postgres :: proc(connection: ^Connection) {
	host := connection.port.host
	client := connection.socket
	hello := db.pg_authentication_ok()
	_ = send(connection, hello)
	delete(hello)
	version := db.pg_parameter_status("server_version", "14.0")
	_ = send(connection, version)
	delete(version)
	ready := db.pg_ready_for_query('I')
	_ = send(connection, ready)
	delete(ready)
	session := db.pg_session_init()
	defer db.pg_session_destroy(session)
	buffer: [64 * 1024]u8
	for {
		n, recv_err := net.recv(client, buffer[:])
		if recv_err != nil || n <= 0 do return
		sync.mutex_lock(&connection.port.statements)
		response, close := db.pg_handle_session_message(host, session, buffer[:n])
		sync.mutex_unlock(&connection.port.statements)
		if len(response) > 0 {
			_ = send(connection, response)
			delete(response)
		}
		if close do return
	}
}

// policy_send queues `bytes` in the client's outbox and writes them. When the
// outbox budget is exceeded the message is discarded and the connection is
// closed on the next write, which is the drop policy.
@(private)
policy_send :: proc(connection: ^Connection, bytes: []u8) -> bool {
	host := connection.port.host
	owner := connection.owner
	if owner == 0 do return send(connection, bytes)
	if !db.host_client_enqueue(host, owner, u64(len(bytes))) do return false
	_ = send(connection, bytes)
	db.host_client_dequeue(host, owner, u64(len(bytes)))
	return !db.host_client_should_drop(host, owner)
}

@(private)
serve_frames :: proc(connection: ^Connection) {
	host := connection.port.host
	client := connection.socket
	owner := connection.owner
	buffer: [64 * 1024]u8
	// A read may carry several frames, or the first half of one: the loop keeps
	// the bytes it has not used and reads again until a whole frame is here.
	held := 0
	for {
		payload, consumed, opcode, frame_err := db.ws_read_frame_within(
			buffer[:held],
			host.max_frame_bytes,
		)
		if frame_err.kind == .Incomplete {
			if held >= len(buffer) do return
			n, recv_err := net.recv(client, buffer[held:])
			if recv_err != nil || n <= 0 do return
			held += n
			continue
		}
		if !db.error_ok(frame_err) do return
		// Keep what followed this frame for the next turn of the loop.
		tail := buffer[consumed:held]
		copy(buffer[:], tail)
		held -= consumed
		if opcode == 8 {
			delete(payload)
			return
		}
		if opcode == 1 || opcode == 2 {
			sync.mutex_lock(&connection.port.statements)
			response := db.wire_request_owned(host, payload, owner)
			sync.mutex_unlock(&connection.port.statements)
			framed := db.ws_frame(response)
			sent := policy_send(connection, framed)
			delete(framed)
			delete(response)
			if !sent {
				delete(payload)
				return
			}
		}
		delete(payload)
		// A fresh connection delivers nothing until it is asked; block here when
		// the buffer is empty rather than spinning on an empty read.
		if held == 0 {
			n, recv_err := net.recv(client, buffer[0:])
			if recv_err != nil || n <= 0 do return
			held = n
		}
	}
}

@(private)
text_bytes :: proc(text: string) -> []u8 {
	out := make([]u8, len(text))
	copy(out, text)
	return out
}
