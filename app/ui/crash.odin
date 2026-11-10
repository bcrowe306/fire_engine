package ui

import "base:runtime"
import "core:debug/trace"

// The crash reporter: on a fatal signal (a bad pointer, a failed
// assertion, a bounds check) the app prints what it was doing — the last
// drive or control command — and a back trace (with names and lines in a
// `-debug` build), then dies as it would have. A harness reads it from
// standard error. Install it with `crash_install` once, at start.

@(private) crash_last: [512]u8
@(private) crash_last_len: int
@(private) crash_installed: bool
@(private) crash_reported: bool // once: a trap after an assertion's report doesn't report again

// Records what the app is doing (the command being run), for a crash
// report. Cheap: a copy into a fixed buffer.
crash_note :: proc "contextless" (what: string) {
	n := min(len(what), len(crash_last))
	for i in 0 ..< n do crash_last[i] = what[i]
	crash_last_len = n
}

// Installs the crash reporter for fatal signals (on Windows, unhandled
// exceptions). For Odin's assertion failures (assert, bounds checks) too,
// set `context.assertion_failure_proc = ui.crash_assertion` in main.
crash_install :: proc() {
	if crash_installed do return
	crash_installed = true
	_crash_install()
}

// Prints the report: the cause, the last command, the stack.
@(private)
crash_report :: proc "contextless" (cause: string) {
	if crash_reported do return
	crash_reported = true
	context = runtime.default_context()
	runtime.print_string("\n=== CRASH: ")
	runtime.print_string(cause)
	runtime.print_string("\n=== last command: ")
	runtime.print_string(string(crash_last[:crash_last_len]) if crash_last_len > 0 else "(none)")
	runtime.print_string("\n=== back trace:\n")
	lines, err := trace.resolve(trace.capture(skip = 2), context.temp_allocator, context.temp_allocator)
	if err != nil {
		runtime.print_string("\t(could not resolve: ")
		runtime.print_string(trace.resolve_err_string(err))
		runtime.print_string(")\n")
	} else {
		trace.print(lines)
	}
	runtime.print_string("=== end of crash report\n")
}

// An assertion failure procedure that reports (as a crash), then stops.
crash_assertion :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
	crash_report(prefix)
	runtime.default_assertion_failure_proc(prefix, message, loc)
}
