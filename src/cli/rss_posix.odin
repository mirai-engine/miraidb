#+build !windows
#+build !linux
package main

import "core:sys/posix"

// cli_current_rss_bytes and cli_peak_rss_bytes report the highest resident set
// the process reached (macOS counts bytes, the BSDs KiB). This platform has no
// portable "resident right now" call, so the gate reads the peak as both and the
// growth it reports is zero; the page pool is still proven by the file size and
// the resident-page count.
cli_current_rss_bytes :: proc() -> u64 {
	return cli_peak_rss_bytes()
}

cli_peak_rss_bytes :: proc() -> u64 {
	usage: posix.rusage
	if posix.getrusage(.SELF, &usage) != .OK do return 0
	peak := u64(usage.ru_maxrss)
	when ODIN_OS == .Darwin {
		return peak
	}
	return peak * 1024
}
