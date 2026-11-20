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
import "core:time"

import db "../engine"

USAGE :: `miraidb-server - HTTP front end for a miraidb database

Usage:
  miraidb-server <database> [--port=8080] [--any] [--allow-host]
                            [--password=PASS] [--statement-timeout-ms=N] [--budget=N]

The PostgreSQL front end authenticates with SCRAM-SHA-256 when --password is
given (or MIRAIDB_PG_PASSWORD is in the environment): the password never crosses
the socket, only proofs over a transcript the server salts. Without it the port
accepts every client, which is what the HTTP front end does too; say so out loud
when it is reachable from anywhere but this machine. A password on the command
line is visible to whoever lists the processes: prefer the environment variable.

The three statements that reach outside the database are refused to clients
unless --allow-host is given: ATTACH reads a file path, LOAD EXTENSION runs host
code, and VACUUM INTO writes a file. A client can name any path or module, so the
default is to believe none of them.

A statement that runs longer than --statement-timeout-ms is cancelled and the
client gets "cancelled"; --budget caps the work one statement may spend (a
statement that overspends is refused instead of answered). Both are off by
default.

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
	statement_timeout_ms := i64(0)
	budget := u64(0)
	password := ""
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
		case strings.has_prefix(arg, "--password="):
			password = arg[len("--password="):]
		case strings.has_prefix(arg, "--statement-timeout-ms="):
			parsed, ok := strconv.parse_int(arg[len("--statement-timeout-ms="):])
			if !ok || parsed < 0 {
				fmt.eprintln("miraidb-server: --statement-timeout-ms needs a number of milliseconds")
				os.exit(2)
			}
			statement_timeout_ms = i64(parsed)
		case strings.has_prefix(arg, "--budget="):
			parsed, ok := strconv.parse_int(arg[len("--budget="):])
			if !ok || parsed < 0 {
				fmt.eprintln("miraidb-server: --budget needs a number of work units")
				os.exit(2)
			}
			budget = u64(parsed)
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
	if budget > 0 do db.store_set_work_budget(store, budget)
	host := db.host_init(store)
	defer db.host_destroy(host)
	server := Server{host = host}
	server.pg_password = password
	if len(server.pg_password) == 0 {
		server.pg_password = os.get_env("MIRAIDB_PG_PASSWORD", context.allocator)
	}
	server.timeout_us = statement_timeout_ms * 1000
	// NOTIFY reaches a listener through the connection the server registered under
	// the owner the statement carried.
	host.store.on_notify = server_deliver_notification
	host.store.on_notify_ctx = &server
	server.connections = make(map[u64]^Connection)
	defer delete(server.connections)
	host.on_update = server_on_update
	host.on_update_ctx = &server
	// One watchdog for the whole server: it watches the statement in flight and
	// cancels it when it has spent its time, which no other thread can do because
	// the thread running the statement is inside it.
	if server.timeout_us > 0 do _ = thread.create_and_start_with_data(&server, statement_watchdog, {})

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
	// registry guards `connections`. It is not the statement lock: a connection
	// has to be able to register, and to finish its startup, while another
	// connection runs a statement or waits inside a transaction. Sharing one
	// mutex made a new client block on a transaction it has nothing to do with.
	registry:    sync.Mutex,
	connections: map[u64]^Connection,
	// pg_password is what the PostgreSQL front end verifies with SCRAM; empty
	// means it asks for nothing.
	pg_password: string,
	// timeout_us is how long one statement may run before the watchdog cancels
	// it; zero leaves it unbounded. The three fields below are the watchdog's
	// view of the statement in flight.
	timeout_us:            i64,
	statement_running:     bool,
	// statement_started_ns is a monotonic tick in nanoseconds, not a wall clock:
	// a clock jump must not look like a statement running for an hour.
	statement_started_ns:  i64,
}

// statement_begin takes the statement lock and tells the watchdog a statement
// started. Every path that runs one goes through here and through
// statement_end, so the watchdog can never see a stale "running".
@(private)
statement_begin :: proc(server: ^Server) {
	sync.mutex_lock(&server.statements)
	// A cancellation belongs to the statement that was running when it was asked
	// for; the next one starts clean.
	db.store_clear_cancel(server.host.store)
	sync.atomic_store(&server.statement_started_ns, time.tick_now()._nsec)
	sync.atomic_store(&server.statement_running, true)
}

@(private)
statement_end :: proc(server: ^Server) {
	sync.atomic_store(&server.statement_running, false)
	sync.mutex_unlock(&server.statements)
}

// statement_pause keeps the statement lock and tells the watchdog nothing is
// running: a Postgres transaction is open and waiting for its client.
@(private)
statement_pause :: proc(server: ^Server) {
	sync.atomic_store(&server.statement_running, false)
}

// statement_resume starts the next statement of a transaction whose connection
// already holds the statement lock.
@(private)
statement_resume :: proc(server: ^Server) {
	db.store_clear_cancel(server.host.store)
	sync.atomic_store(&server.statement_started_ns, time.tick_now()._nsec)
	sync.atomic_store(&server.statement_running, true)
}

// statement_watchdog cancels a statement that has spent its time. Cancellation
// is cooperative: the executor checks the flag between rows and answers
// `cancelled`, so the client gets an error instead of a dead server.
@(private)
statement_watchdog :: proc(data: rawptr) {
	server := (^Server)(data)
	for {
		time.sleep(2 * time.Millisecond)
		if !sync.atomic_load(&server.statement_running) do continue
		elapsed_us := (time.tick_now()._nsec - sync.atomic_load(&server.statement_started_ns)) / 1000
		if elapsed_us < server.timeout_us do continue
		if sync.atomic_load(&server.statement_running) {
			db.store_cancel(server.host.store)
		}
	}
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
	sync.mutex_lock(&server.registry)
	server.connections[connection.owner] = connection
	sync.mutex_unlock(&server.registry)
}

@(private)
server_forget :: proc(server: ^Server, connection: ^Connection) {
	sync.mutex_lock(&server.registry)
	delete_key(&server.connections, connection.owner)
	sync.mutex_unlock(&server.registry)
}

// server_on_update is called from the thread that ran the commit. It finds the
// connection that owns the subscription and writes one delta frame into it.
@(private)
server_on_update :: proc(ctx: rawptr, update: ^db.Subscription_Update) {
	server := (^Server)(ctx)
	if server == nil do return
	owner := db.host_subscription_owner(server.host, update.subscription_id)
	if owner == 0 do return
	sync.mutex_lock(&server.registry)
	connection, exists := server.connections[owner]
	sync.mutex_unlock(&server.registry)
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
		statement_begin(connection.port)
		db.host_client_disconnect(host, owner)
		statement_end(connection.port)
	}
	buffer: [64 * 1024]u8
	n, recv_err := net.recv(client, buffer[:])
	if recv_err != nil || n <= 0 do return
	if db.pg_is_startup(buffer[:n]) {
		// A startup that begins with an SSLRequest is a question, not a session:
		// the answer is one byte, 'S' to continue with TLS or 'N' to continue in
		// the clear. Answering the authentication request instead desynchronises
		// libpq, whose default sslmode is `prefer`, so psql and psycopg could not
		// connect at all without sslmode=disable. This server has no TLS, so the
		// answer is N and the loop waits for the real startup that follows.
		for {
			probe, probe_ok := db.pg_parse_startup(buffer[:n])
			if !probe_ok || !probe.ssl_request do break
			refusal := []u8{'N'}
			_ = send(connection, refusal[:])
			n, recv_err = net.recv(client, buffer[:])
			if recv_err != nil || n <= 0 do return
		}
		if db.pg_is_startup(buffer[:n]) {
			serve_postgres(connection)
			return
		}
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
		statement_begin(connection.port)
		if identity, valid := db.host_authenticate(host, token); valid {
			db.store_set_identity(host.store, identity)
		}
		statement_end(connection.port)
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
		// Only the kind is read: every message goes, incomplete or not.
		kind := parse_err.kind
		db.error_free(&parse_err)
		if kind != .Incomplete {
			status := 400
			if kind == .Quota_Exceeded do status = 413
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
	statement_begin(connection.port)
	response := db.http_handle(host, request)
	db.http_request_destroy(&request)
	statement_end(connection.port)
	_ = send(connection, response)
	delete(response)
}

// serve_frames runs the WebSocket loop: each binary or text frame carries one
// wire message and the answer goes back in one binary frame.
// Pg_Auth is where a PostgreSQL connection is in its startup.
Pg_Auth :: enum {
	// Password: the SASL initial response is expected.
	Password,
	// Challenge: the client's proof is expected.
	Challenge,
	// Ready: authenticated (or nothing was asked for), queries are handled.
	Ready,
	// Failed: an error was sent and the connection must close.
	Failed,
}

// pg_ready_bytes is AuthenticationOk, the parameters every PostgreSQL server
// reports, and ReadyForQuery, in one buffer.
@(private)
pg_ready_bytes :: proc() -> []u8 {
	out := make([dynamic]u8, 0, 256)
	hello := db.pg_authentication_ok()
	append(&out, ..hello)
	delete(hello)
	// Drivers read these without checking: psycopg's C build crashed on a null
	// `client_encoding` when only `server_version` was sent.
	for parameter in db.PG_STARTUP_PARAMETERS {
		status := db.pg_parameter_status(parameter[0], parameter[1])
		append(&out, ..status)
		delete(status)
	}
	ready := db.pg_ready_for_query('I')
	append(&out, ..ready)
	delete(ready)
	return out[:]
}

// pg_authenticate advances the SCRAM exchange by one message and answers the
// bytes to send. It touches no database state, so it runs without the statement
// lock: a client must be able to authenticate while another one runs a query.
@(private)
pg_authenticate :: proc(
	scram: ^db.Pg_Scram,
	state: Pg_Auth,
	message: []u8,
) -> (
	response: []u8,
	next: Pg_Auth,
) {
	if len(message) == 0 || message[0] != 'p' {
		return db.pg_error_response("expected a SASL message", "08P01"), .Failed
	}
	switch state {
	case .Password:
		mechanism, initial, parsed := db.pg_sasl_initial(message)
		if !parsed || mechanism != db.PG_SCRAM_MECHANISM {
			return db.pg_error_response("only SCRAM-SHA-256 is supported", "28000"), .Failed
		}
		if err := db.pg_scram_client_first(scram, initial); err.kind != .None {
			return db.pg_error_response(err.message, db.pg_sqlstate(err.kind)), .Failed
		}
		challenge := db.pg_scram_server_first(scram)
		defer delete(challenge)
		return db.pg_authentication_sasl_continue(challenge), .Challenge
	case .Challenge:
		text, parsed := db.pg_sasl_response(message)
		if !parsed {
			return db.pg_error_response("malformed SASL response", "08P01"), .Failed
		}
		answer, err := db.pg_scram_finish(scram, text)
		if err.kind != .None {
			// One message for a wrong password and for a malformed proof: a
			// client learns that it failed, not why.
			return db.pg_error_response("invalid username or password", "28P01"), .Failed
		}
		defer delete(answer)
		final := db.pg_authentication_sasl_final(answer)
		defer delete(final)
		ready := pg_ready_bytes()
		defer delete(ready)
		joined := make([dynamic]u8, 0, len(final) + len(ready))
		append(&joined, ..final)
		append(&joined, ..ready)
		return joined[:], .Ready
	case .Ready, .Failed:
		return nil, state
	}
	return nil, state
}

// server_deliver_notification writes one NOTIFY to the connection that listens for
// it, as the asynchronous message the protocol defines.
@(private)
server_deliver_notification :: proc(ctx: rawptr, owner: u64, channel, payload: string) {
	server := (^Server)(ctx)
	fmt.eprintfln("DBG deliver to owner=%d", owner)
	sync.mutex_lock(&server.registry)
	connection, found := server.connections[owner]
	sync.mutex_unlock(&server.registry)
	if !found do return
	fmt.eprintfln("DBG deliver found=%v", found)
	message := db.pg_notification_response(channel, payload)
	defer delete(message)
	// A notification is not the answer to a message; it goes out on its own, under
	// the send lock the connection already takes for every write.
	_ = send(connection, message)
}

// serve_postgres answers the startup and then handles simple-query messages.
@(private)
serve_postgres :: proc(connection: ^Connection) {
	host := connection.port.host
	client := connection.socket
	// A configured password is checked before the session exists: SCRAM proves
	// it without sending it, and the connection is refused until it does.
	auth := Pg_Auth.Ready
	scram: db.Pg_Scram
	defer db.pg_scram_destroy(&scram)
	if len(connection.port.pg_password) > 0 {
		scram = db.pg_scram_start(connection.port.pg_password)
		offer := db.pg_authentication_sasl()
		_ = send(connection, offer)
		delete(offer)
		auth = .Password
	} else {
		ready := pg_ready_bytes()
		_ = send(connection, ready)
		delete(ready)
	}
	session := db.pg_session_init()
	session.owner = connection.owner
	// A BEGIN holds the store's write lock until COMMIT or ROLLBACK, so the
	// connection keeps the statement lock for that whole time: another
	// connection waits for the transaction instead of taking the statement lock
	// and then blocking on the store forever while this one cannot get back in
	// to commit. `holding` says the lock is this connection's between messages.
	holding := false
	defer {
		db.pg_session_destroy(session)
		if holding do statement_end(connection.port)
	}
	// A read is not a message: a driver sends Parse, Bind, Describe, Execute and
	// Sync in one packet, and a large Query arrives in several. `pending` holds
	// what has arrived, and each complete message (a type byte and a length that
	// counts itself) is handled in order. Treating one read as one message lost
	// everything after the first, and psycopg waited forever for its Sync.
	pending := make([dynamic]u8, 0, 64 * 1024)
	defer delete(pending)
	buffer: [64 * 1024]u8
	for {
		n, recv_err := net.recv(client, buffer[:])
		if recv_err != nil || n <= 0 do return
		append(&pending, ..buffer[:n])
		for len(pending) >= 5 {
			length := int(u32(pending[1]) << 24 | u32(pending[2]) << 16 | u32(pending[3]) << 8 | u32(pending[4]))
			if length > PG_MAX_MESSAGE do return
			total := length >= 4 ? 1 + length : len(pending)
			if len(pending) < total do break
			if auth != .Ready {
				// Authentication runs outside the statement lock, so a client can
				// connect and prove itself while another one is mid-transaction.
				response, next := pg_authenticate(&scram, auth, pending[:total])
				auth = next
				remove_range(&pending, 0, total)
				if len(response) > 0 {
					_ = send(connection, response)
					delete(response)
				}
				if auth == .Failed do return
				continue
			}
			if holding {
				statement_resume(connection.port)
			} else {
				statement_begin(connection.port)
			}
			// The statement runs on behalf of this connection: LISTEN and NOTIFY
			// read the identity from the store while the statement lock is held.
			host.store.session_owner = connection.owner
			response, close := db.pg_handle_session_message(host, session, pending[:total])
			holding = db.pg_session_in_transaction(session)
			if holding {
				// Idle in a transaction: the watchdog must not time the wait for
				// the client's next message as a running statement.
				statement_pause(connection.port)
			} else {
				statement_end(connection.port)
			}
			remove_range(&pending, 0, total)
			if len(response) > 0 {
				_ = send(connection, response)
				delete(response)
			}
			if close do return
		}
	}
}

// PG_MAX_MESSAGE bounds one frontend message, so a length field cannot make the
// server buffer without limit. PostgreSQL's own limit for a query is 1 GiB; this
// engine has no use for one larger than this.
PG_MAX_MESSAGE :: 64 * 1024 * 1024

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
			statement_begin(connection.port)
			response := db.wire_request_owned(host, payload, owner)
			statement_end(connection.port)
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
