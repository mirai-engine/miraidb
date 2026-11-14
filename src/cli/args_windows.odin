#+build windows
package main

import "core:os"
import win32 "core:sys/windows"

// cli_args returns the process arguments decoded as UTF-8.
//
// os.args on Windows comes from the ANSI command line, so an argument the user
// typed as "é" arrives as the single byte 0xE9 where the console held a UTF-16
// code point. Re-reading the wide command line is the only way to see what was
// actually typed (backlog D32).
cli_args :: proc(allocator := context.allocator) -> []string {
	count := i32(0)
	wide := win32.CommandLineToArgvW(win32.GetCommandLineW(), &count)
	if wide == nil || count <= 0 do return os.args
	defer win32.LocalFree(rawptr(wide))
	args := make([]string, int(count), allocator)
	for i in 0 ..< int(count) {
		text, err := win32.wstring_to_utf8(wide[i], -1, allocator)
		args[i] = err == nil ? text : ""
	}
	return args
}
