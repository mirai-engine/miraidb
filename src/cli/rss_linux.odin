#+build linux
package main

import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

// cli_current_rss_bytes is the resident set right now, read from /proc. The
// memory gate takes it after opening the database so the number it reports is
// what the statement added, not what startup cost.
cli_current_rss_bytes :: proc() -> u64 {
	data, read_err := os.read_entire_file_from_path("/proc/self/statm", context.allocator)
	if read_err != nil do return 0
	defer delete(data)
	fields := strings.fields(string(data))
	if len(fields) < 2 do return 0
	pages, ok := strconv.parse_u64(fields[1])
	if !ok do return 0
	return pages * 4096
}

// cli_peak_rss_bytes is the highest resident set the process reached, in bytes.
cli_peak_rss_bytes :: proc() -> u64 {
	usage: posix.rusage
	if posix.getrusage(.SELF, &usage) != .OK do return 0
	return u64(usage.ru_maxrss) * 1024
}
