package engine

import "core:fmt"
import "core:strings"

// The HTTP layer is the transport half of the server. It stays free of sockets
// so the protocol logic is testable: a socket loop reads bytes,
// http_parse_request turns them into a request, http_handle routes it (wire
// messages for /call, /query, /subscribe and /unsubscribe) and http_response
// frames the answer with Connection: close.

// The transport caps a request and a WebSocket frame; a socket loop passes its
// own limits, these are the defaults for callers that do not care.
HTTP_DEFAULT_MAX_HEADER :: 16 * 1024
HTTP_DEFAULT_MAX_BODY :: 1 << 20

Http_Request :: struct {
	method:        string,
	path:          string,
	body:          []u8,
	// accepts_zlib reports `Accept-Encoding: zlib`; zlib_body reports a
	// `Content-Encoding: zlib` request body.
	accepts_zlib:  bool,
	zlib_body:     bool,
}

http_parse_request :: proc(data: []u8) -> (request: Http_Request, consumed: int, err: Error) {
	return http_parse_request_within(data, HTTP_DEFAULT_MAX_HEADER, HTTP_DEFAULT_MAX_BODY)
}

// http_parse_request_within parses one request and refuses a header or a body
// over its limit before touching the payload. Zero disables a limit.
http_parse_request_within :: proc(
	data: []u8,
	max_header: int,
	max_body: int,
) -> (request: Http_Request, consumed: int, err: Error) {
	header_end := strings.index(string(data), "\r\n\r\n")
	if header_end < 0 {
		return {}, 0, errf(.Invalid_Argument, "incomplete HTTP request")
	}
	if max_header > 0 && header_end + 4 > max_header {
		return {}, 0, errf(
			.Quota_Exceeded,
			"HTTP header is %d bytes, more than the %d byte limit",
			header_end + 4,
			max_header,
		)
	}
	head := string(data[:header_end])
	lines := strings.split(head, "\r\n")
	defer delete(lines)
	if len(lines) == 0 {
		return {}, 0, errf(.Invalid_Argument, "empty HTTP request")
	}
	parts := strings.split(lines[0], " ")
	defer delete(parts)
	if len(parts) < 3 {
		return {}, 0, errf(.Invalid_Argument, "bad HTTP request line")
	}
	request.method = strings.clone(parts[0])
	request.path = strings.clone(parts[1])

	content_length := 0
	for line, i in lines {
		if i == 0 do continue
		lower := strings.to_lower(line)
		defer delete(lower)
		if strings.has_prefix(lower, "accept-encoding:") {
			if strings.contains(lower, "zlib") do request.accepts_zlib = true
			continue
		}
		if strings.has_prefix(lower, "content-encoding:") {
			value := strings.trim_space(line[len("content-encoding:"):])
			if strings.equal_fold(value, "zlib") do request.zlib_body = true
			continue
		}
		if !strings.has_prefix(lower, "content-length:") do continue
		value := strings.trim_space(line[len("content-length:"):])
		for c in value {
			if c < '0' || c > '9' {
				return request, 0, errf(.Invalid_Argument, "bad Content-Length")
			}
			content_length = content_length * 10 + int(c - '0')
			if content_length < 0 || (max_body > 0 && content_length > max_body) {
				return {}, 0, errf(
					.Quota_Exceeded,
					"HTTP body is more than the %d byte limit",
					max_body,
				)
			}
		}
	}
	body_start := header_end + 4
	consumed = body_start + content_length
	if consumed > len(data) {
		return request, 0, errf(.Invalid_Argument, "incomplete HTTP body")
	}
	request.body = data[body_start:consumed]
	return request, consumed, ERROR_NONE
}

@(private)
http_bytes :: proc(text: string) -> []u8 {
	out := make([]u8, len(text))
	copy(out, text)
	return out
}

http_response :: proc(status: int, content_type: string, body: []u8) -> []u8 {
	reason := "OK"
	switch status {
	case 200:
	case 400:
		reason = "Bad Request"
	case 404:
		reason = "Not Found"
	case 405:
		reason = "Method Not Allowed"
	case 413:
		reason = "Payload Too Large"
	case 431:
		reason = "Request Header Fields Too Large"
	case 500:
		reason = "Internal Server Error"
	case:
	}
	header := fmt.aprintf(
		"HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n",
		status,
		reason,
		content_type,
		len(body),
	)
	defer delete(header)
	out := make([]u8, len(header) + len(body))
	copy(out, header)
	copy(out[len(header):], body)
	return out
}

// http_bearer_token reads the Authorization header when it uses the Bearer
// scheme. The socket loop calls it before routing so policies see the caller.
http_bearer_token :: proc(request: []u8) -> (string, bool) {
	text := string(request)
	lower := strings.to_lower(text)
	defer delete(lower)
	position := strings.index(lower, "authorization:")
	if position < 0 do return "", false
	start := position + len("authorization:")
	end := start
	for end < len(text) && text[end] != '\r' && text[end] != '\n' do end += 1
	value := strings.trim_space(text[start:end])
	if !strings.has_prefix(strings.to_lower(value), "bearer ") do return "", false
	return strings.trim_space(value[len("bearer "):]), true
}

// client_drops sums the messages the outbox policy discarded.
@(private)
client_drops :: proc(host: ^Host) -> u64 {
	total: u64
	for _, client in host.clients do total += client.dropped
	return total
}

// http_handle routes a parsed request. Every data endpoint accepts one wire
// message, so the same dispatcher serves plain queries, reducer calls and
// subscriptions.
http_handle :: proc(host: ^Host, request: Http_Request) -> []u8 {
	if host != nil && host.max_request_bytes > 0 && len(request.body) > host.max_request_bytes {
		return http_response(413, "text/plain", http_bytes("request body too large"))
	}
	effective := request
	if request.zlib_body && len(request.body) > 0 {
		if body, ok := zlib_decompress(request.body, context.temp_allocator); ok {
			effective.body = body
		}
	}
	response := http_dispatch(host, effective)
	if request.accepts_zlib && len(response) > 0 {
		return http_compress_response(response)
	}
	return response
}

// http_compress_response rebuilds a plain response with a zlib body.
@(private)
http_compress_response :: proc(raw: []u8) -> []u8 {
	header_end := strings.index(string(raw), "\r\n\r\n")
	if header_end < 0 do return raw
	head := string(raw[:header_end])
	body := raw[header_end + 4:]
	lines := strings.split(head, "\r\n")
	defer delete(lines)
	if len(lines) == 0 do return raw
	content_type := "application/octet-stream"
	for line, i in lines {
		if i == 0 do continue
		lower := strings.to_lower(line)
		defer delete(lower)
		if strings.has_prefix(lower, "content-type:") {
			content_type = strings.trim_space(line[len("content-type:"):])
		}
	}
	compressed := zlib_compress(body, context.temp_allocator)
	builder := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&builder,
		"%s\r\nContent-Type: %s\r\nContent-Encoding: zlib\r\nContent-Length: %d\r\n\r\n",
		lines[0],
		content_type,
		len(compressed),
	)
	text := transmute([]u8)strings.to_string(builder)
	out := make([dynamic]u8, 0, len(text) + len(compressed))
	append(&out, ..text)
	append(&out, ..compressed)
	return out[:]
}

@(private)
http_dispatch :: proc(host: ^Host, request: Http_Request) -> []u8 {
	if request.method == "GET" && request.path == "/health" {
		return http_response(200, "text/plain", http_bytes("ok"))
	}
	if request.method == "GET" && request.path == "/metrics" {
		body := fmt.aprintf(
			"# TYPE miraidb_requests_total counter\nmiraidb_requests_total %d\n" +
			"# TYPE miraidb_errors_total counter\nmiraidb_errors_total %d\n" +
			"# TYPE miraidb_commit_seq gauge\nmiraidb_commit_seq %d\n" +
			"# TYPE miraidb_subscriptions gauge\nmiraidb_subscriptions %d\n" +
			"# TYPE miraidb_clients gauge\nmiraidb_clients %d\n" +
			"# TYPE miraidb_client_drops_total counter\nmiraidb_client_drops_total %d\n",
			host.metric_requests,
			host.metric_errors,
			host.store.commit_seq,
			len(host.subscriptions),
			len(host.clients),
			client_drops(host),
		)
		defer delete(body)
		return http_response(200, "text/plain; version=0.0.4", http_bytes(body))
	}
	if request.method == "GET" && request.path == "/schema" {
		body := host_schema_text(host, context.temp_allocator)
		return http_response(200, "text/plain", http_bytes(body))
	}
	if request.method != "POST" {
		return http_response(405, "text/plain", http_bytes("method not allowed"))
	}
	switch request.path {
	case "/call", "/query", "/subscribe", "/unsubscribe", "/wire":
		body := wire_request(host, request.body)
		response := http_response(200, "application/octet-stream", body)
		delete(body)
		return response
	}
	return http_response(404, "text/plain", http_bytes("not found"))
}
