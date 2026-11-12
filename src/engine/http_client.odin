package engine

import "core:mem"
import "core:net"
import "core:strings"

// Http_Transport sends the raw request bytes and returns the raw response. The
// caller supplies a real TCP transport or a test double, which keeps the client
// logic independent from sockets.
Http_Transport :: proc(ctx: rawptr, request: []u8, alloc: mem.Allocator) -> ([]u8, Error)

Http_Response :: struct {
	status: int,
	body:   []u8,
	// zlib reports `Content-Encoding: zlib` on the response.
	zlib:   bool,
}

// http_parse_response parses the status line, the headers and the body. The
// body honours Content-Length when present and otherwise runs to the end.
http_parse_response :: proc(data: []u8) -> (Http_Response, Error) {
	header_end := strings.index(string(data), "\r\n\r\n")
	if header_end < 0 do return {}, errf(.Invalid_Argument, "incomplete HTTP response")
	lines := strings.split(string(data[:header_end]), "\r\n")
	defer delete(lines)
	if len(lines) == 0 do return {}, errf(.Invalid_Argument, "empty HTTP response")
	parts := strings.split(lines[0], " ")
	defer delete(parts)
	if len(parts) < 2 do return {}, errf(.Invalid_Argument, "bad HTTP status line")
	status := 0
	for c in parts[1] {
		if c < '0' || c > '9' do return {}, errf(.Invalid_Argument, "bad HTTP status code")
		status = status * 10 + int(c - '0')
	}
	body := data[header_end + 4:]
	compressed := false
	for line, i in lines {
		if i == 0 do continue
		lower := strings.to_lower(line)
		defer delete(lower)
		if strings.has_prefix(lower, "content-encoding:") {
			value := strings.trim_space(line[len("content-encoding:"):])
			if strings.equal_fold(value, "zlib") do compressed = true
			continue
		}
		if !strings.has_prefix(lower, "content-length:") do continue
		length := 0
		for c in strings.trim_space(line[len("content-length:"):]) {
			if c < '0' || c > '9' do return {}, errf(.Invalid_Argument, "bad Content-Length")
			length = length * 10 + int(c - '0')
		}
		if length > len(body) do return {}, errf(.Invalid_Argument, "short HTTP body")
		body = body[:length]
	}
	return Http_Response{status = status, body = body, zlib = compressed}, ERROR_NONE
}

// Http_Split_Url splits `http://authority/path` into its parts.
Http_Split_Url :: proc(url: string) -> (authority: string, path: string, err: Error) {
	if !strings.has_prefix(url, "http://") {
		return "", "", errf(.Invalid_Argument, "only http:// URLs are supported")
	}
	rest := url[len("http://"):]
	slash := strings.index(rest, "/")
	if slash < 0 do return rest, "/", ERROR_NONE
	return rest[:slash], rest[slash:], ERROR_NONE
}

// http_get_via performs one GET through the given transport.
http_get_via :: proc(
	transport: Http_Transport,
	ctx: rawptr,
	url: string,
	alloc: mem.Allocator,
) -> (Http_Response, Error) {
	if transport == nil do return {}, errf(.Invalid_Argument, "no HTTP transport")
	authority, path, split_err := Http_Split_Url(url)
	if split_err.kind != .None do return {}, split_err
	if len(authority) == 0 do return {}, errf(.Invalid_Argument, "the URL has no host")
	request := strings.concatenate(
		{
			"GET ",
			path,
			" HTTP/1.1\r\nHost: ",
			authority,
			"\r\nAccept-Encoding: zlib\r\nConnection: close\r\n\r\n",
		},
	)
	defer delete(request)
	raw, send_err := transport(ctx, transmute([]u8)request, alloc)
	if send_err.kind != .None do return {}, send_err
	return http_parse_response(raw)
}

// Tcp_Target is the transport context: the authority to connect to.
Tcp_Target :: struct {
	authority: string,
}

// http_tcp_transport connects to the authority, sends the request and reads
// until the peer closes the connection.
http_tcp_transport :: proc(
	ctx: rawptr,
	request: []u8,
	alloc: mem.Allocator,
) -> ([]u8, Error) {
	target := (^Tcp_Target)(ctx)
	authority := target.authority
	host_name := authority
	port_text := "80"
	if colon := strings.last_index(authority, ":"); colon >= 0 {
		host_name = authority[:colon]
		port_text = authority[colon + 1:]
	}
	endpoint := strings.concatenate({host_name, ":", port_text})
	defer delete(endpoint)
	socket, dial_err := net.dial_tcp(endpoint)
	if dial_err != nil {
		return nil, errf(.Io, "cannot connect to %s: %v", authority, dial_err)
	}
	defer net.close(socket)
	if _, send_err := net.send(socket, request); send_err != nil {
		return nil, errf(.Io, "cannot send the request: %v", send_err)
	}
	response := make([dynamic]u8, 0, 1024, alloc)
	buffer: [4096]u8
	for {
		read, recv_err := net.recv(socket, buffer[:])
		if recv_err != nil do break
		if read <= 0 do break
		append(&response, ..buffer[:read])
	}
	if len(response) == 0 {
		return nil, errf(.Io, "the server closed without a response")
	}
	return response[:], ERROR_NONE
}

// http_get performs a blocking GET over TCP. Intended for procedures and
// modules, not for the request path of the server.
http_get :: proc(url: string, alloc: mem.Allocator) -> (Http_Response, Error) {
	authority, _, split_err := Http_Split_Url(url)
	if split_err.kind != .None do return {}, split_err
	target := Tcp_Target{authority = authority}
	return http_get_via(http_tcp_transport, &target, url, alloc)
}
