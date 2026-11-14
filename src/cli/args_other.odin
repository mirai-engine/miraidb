#+build !windows
package main

import "core:os"

// cli_args returns the process arguments. A POSIX system hands them over as
// bytes, which are already UTF-8 (backlog D32).
cli_args :: proc(allocator := context.allocator) -> []string {
	return os.args
}
