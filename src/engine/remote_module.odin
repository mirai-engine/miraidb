package engine

import "core:fmt"
import "core:mem"
import "core:net"
import "core:strings"
import "core:sync"
import "core:time"

// A remote module is a process that speaks the wire protocol. The host sends one
// call message and reads one result message, framed as a little-endian u32
// length followed by the payload, so neither side has to half-close the socket.
// Only bytes cross the boundary: no engine struct, and therefore no allocator
// contract to get wrong.

REMOTE_MODULE_MAX_BYTES :: 1 << 20
REMOTE_MODULE_TIMEOUT_MS :: 5000

// Remote_Conn is one pooled connection to a module.
Remote_Conn :: struct {
	socket: net.TCP_Socket,
}

Remote_Module :: struct {
	host:     string,
	port:     int,
	reducers: []string,
}

// host_register_remote_module records a module that runs in another process. It
// does not connect yet: the connection is opened per call, so a module that is
// down fails its call instead of the host.
host_register_remote_module :: proc(
	host: ^Host,
	name: string,
	address: string,
	port: int,
	reducers: []string,
) -> Error {
	if host == nil do return errf(.Invalid_Argument, "no host")
	if len(name) == 0 do return errf(.Invalid_Argument, "a module needs a name")
	if len(address) == 0 do return errf(.Invalid_Argument, "module %s needs an address", name)
	if port <= 0 || port > 65535 do return errf(.Invalid_Argument, "module %s needs a port", name)
	if _, exists := host.modules[name]; exists {
		return errf(.Invalid_Argument, "module %s is already registered", name)
	}
	if _, exists := host.remote_modules[name]; exists {
		return errf(.Invalid_Argument, "module %s is already registered", name)
	}
	host.remote_modules[strings.clone(name)] = Remote_Module {
		host     = strings.clone(address),
		port     = port,
		reducers = slice_clone_strings(reducers),
	}
	return ERROR_NONE
}

@(private)
slice_clone_strings :: proc(values: []string) -> []string {
	out := make([]string, len(values))
	for value, i in values do out[i] = strings.clone(value)
	return out
}

// host_unregister_remote_module forgets a module. A call to it from then on fails
// as an unknown module, which is what an unloaded extension should do.
host_unregister_remote_module :: proc(host: ^Host, name: string) {
	module, found := host.remote_modules[name]
	if !found do return
	for key in host.remote_modules {
		if strings.equal_fold(key, name) {
			delete_key(&host.remote_modules, key)
			break
		}
	}
	delete(module.host)
	for reducer in module.reducers do delete(reducer)
	delete(module.reducers)
}

host_remote_module_names :: proc(host: ^Host, alloc: mem.Allocator) -> []string {
	names := make([dynamic]string, 0, len(host.remote_modules), alloc)
	for name in host.remote_modules do append(&names, name)
	slice_sort_strings(names[:])
	return names[:]
}

@(private)
host_remote_modules_destroy :: proc(host: ^Host) {
	for name, module in host.remote_modules {
		delete(name)
		delete(module.host)
		for reducer in module.reducers do delete(reducer)
		delete(module.reducers)
	}
	delete(host.remote_modules)
}

// host_call_remote_module forwards one reducer call to a remote module and
// returns its acknowledgement. The module owns its own transactions and data;
// the host only learns whether the call succeeded.
host_call_remote_module :: proc(
	host: ^Host,
	module_name: string,
	reducer: string,
	args: []Value,
) -> (Value, Error) {
	module, found := host.remote_modules[module_name]
	if !found do return {}, errf(.Invalid_Argument, "no module named %s", module_name)
	if len(module.reducers) > 0 {
		known := false
		for name in module.reducers {
			if strings.equal_fold(name, reducer) {
				known = true
				break
			}
		}
		if !known {
			return {}, errf(.Sql_Unsupported, "module %s has no reducer %s", module_name, reducer)
		}
	}
	// Every call gets its own request id: the module side keeps idempotency, so two
	// calls with the same id would make the second one a cached acknowledgement
	// instead of a second execution.
	host.next_request_id += 1
	request := wire_encode_call(host.next_request_id, reducer, args, host_now(host))
	defer delete(request)
	response, call_err := remote_module_send(host, module, request)
	if call_err.kind != .None do return {}, call_err
	defer delete(response)
	if wire_message_kind(response) == WIRE_ERROR {
		decode_err, ok := wire_decode_error(response, context.allocator)
		if ok do return {}, decode_err
		return {}, errf(.Internal, "module %s answered an error it cannot decode", module_name)
	}
	result, decode_err := wire_decode_result(response, context.allocator)
	if decode_err.kind != .None {
		return {}, errf(.Internal, "module %s sent an invalid reply: %s", module_name, decode_err.message)
	}
	defer sql_result_destroy(&result)
	// A reducer reports success through the call itself; its value stays on the
	// module side.
	return value_int(i64(result.affected)), ERROR_NONE
}

// remote_module_send frames one message, waits for the reply and caps it. The
// timeout is set on the socket, so a hung module fails the call.
remote_module_send :: proc(host: ^Host, module: Remote_Module, payload: []u8) -> ([]u8, Error) {
	max_bytes := REMOTE_MODULE_MAX_BYTES
	if host != nil && host.max_request_bytes > 0 do max_bytes = host.max_request_bytes
	if len(payload) > max_bytes {
		return nil, errf(.Quota_Exceeded, "message of %d bytes exceeds the %d byte limit", len(payload), max_bytes)
	}
	port_text := fmt.aprintf("%d", module.port, allocator = context.temp_allocator)
	key := strings.concatenate({module.host, ":", port_text}, context.temp_allocator)
	// Two attempts: a pooled socket may have been closed by the peer while it sat
	// idle, so a failure drops it and redials once instead of failing the call.
	socket: net.TCP_Socket
	fresh := true
	for attempt in 0 ..< 2 {
		if attempt == 0 {
			if pooled, ok := remote_conn_take(host, key); ok {
				socket = pooled
				fresh = false
			}
		}
		if fresh {
			dialed, dial_err := net.dial_tcp(module.host, module.port)
			if dial_err != nil {
				return nil, errf(.Io, "cannot reach module at %s:%d: %v", module.host, module.port, dial_err)
			}
			socket = dialed
			timeout := time.Duration(REMOTE_MODULE_TIMEOUT_MS) * time.Millisecond
			net.set_option(socket, .Receive_Timeout, timeout)
			net.set_option(socket, .Send_Timeout, timeout)
		}
		response, call_err := remote_module_exchange(socket, module, payload, max_bytes)
		if call_err.kind == .None {
			remote_conn_put(host, key, socket)
			return response, ERROR_NONE
		}
		net.close(socket)
		if attempt == 1 do return nil, call_err
		fresh = true
	}
	return nil, errf(.Io, "cannot reach module at %s:%d", module.host, module.port)
}

@(private)
remote_module_exchange :: proc(
	socket: net.TCP_Socket,
	module: Remote_Module,
	payload: []u8,
	max_bytes: int,
) -> ([]u8, Error) {
	header: [4]u8
	put_u32_le(header[:], u32(len(payload)))
	if _, send_err := net.send(socket, header[:]); send_err != nil {
		return nil, errf(.Io, "cannot send to module at %s:%d", module.host, module.port)
	}
	if _, send_err := net.send(socket, payload); send_err != nil {
		return nil, errf(.Io, "cannot send to module at %s:%d", module.host, module.port)
	}
	length, read_err := remote_module_read_length(socket, module)
	if read_err.kind != .None do return nil, read_err
	if length > max_bytes {
		return nil, errf(.Quota_Exceeded, "module reply of %d bytes exceeds the %d byte limit", length, max_bytes)
	}
	out := make([]u8, length)
	total := 0
	for total < length {
		read, recv_err := net.recv(socket, out[total:])
		if recv_err != nil || read <= 0 {
			delete(out)
			return nil, errf(.Io, "module at %s:%d closed the connection", module.host, module.port)
		}
		total += read
	}
	return out, ERROR_NONE
}

// remote_conn_take removes a pooled socket: one call owns it at a time.
@(private)
remote_conn_take :: proc(host: ^Host, key: string) -> (net.TCP_Socket, bool) {
	if host == nil do return {}, false
	sync.lock(&host.remote_mutex)
	defer sync.unlock(&host.remote_mutex)
	conn, found := host.remote_conns[key]
	if !found do return {}, false
	delete_key(&host.remote_conns, key)
	return conn.socket, true
}

@(private)
remote_conn_put :: proc(host: ^Host, key: string, socket: net.TCP_Socket) {
	if host == nil do return
	sync.lock(&host.remote_mutex)
	defer sync.unlock(&host.remote_mutex)
	host.remote_conns[strings.clone(key, context.allocator)] = Remote_Conn{socket = socket}
}

// remote_conns_close drops every pooled socket; host_destroy calls it.
host_remote_conns_close :: proc(host: ^Host) {
	if host == nil do return
	sync.lock(&host.remote_mutex)
	defer sync.unlock(&host.remote_mutex)
	for key, conn in host.remote_conns {
		net.close(conn.socket)
		delete(key)
	}
	delete(host.remote_conns)
}

@(private)
remote_module_read_length :: proc(socket: net.TCP_Socket, module: Remote_Module) -> (int, Error) {
	header: [4]u8
	total := 0
	for total < 4 {
		read, recv_err := net.recv(socket, header[total:])
		if recv_err != nil || read <= 0 {
			return 0, errf(.Io, "module at %s:%d closed the connection", module.host, module.port)
		}
		total += read
	}
	return int(get_u32_le(header[:])), ERROR_NONE
}
