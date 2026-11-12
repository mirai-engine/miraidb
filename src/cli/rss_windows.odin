#+build windows
package main

import "core:sys/windows"

@(private)
process_memory :: proc(counters: ^windows.PROCESS_MEMORY_COUNTERS) -> bool {
	return windows.GetProcessMemoryInfo(
		windows.GetCurrentProcess(),
		counters,
		u32(size_of(counters^)),
	) != false
}

// cli_current_rss_bytes is the working set right now. The memory gate reads it
// after opening the database and again after the statement, so the number it
// reports is what the query added, not what startup cost.
cli_current_rss_bytes :: proc() -> u64 {
	counters: windows.PROCESS_MEMORY_COUNTERS
	if !process_memory(&counters) do return 0
	return u64(counters.WorkingSetSize)
}

// cli_peak_rss_bytes is the highest working set this process reached.
cli_peak_rss_bytes :: proc() -> u64 {
	counters: windows.PROCESS_MEMORY_COUNTERS
	if !process_memory(&counters) do return 0
	return u64(counters.PeakWorkingSetSize)
}
