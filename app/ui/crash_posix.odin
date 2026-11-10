#+build darwin, linux, freebsd, openbsd, netbsd
package ui

import "core:sys/posix"

@(private)
_crash_install :: proc() {
	act: posix.sigaction_t
	act.sa_handler = crash_signal
	act.sa_flags = {.RESETHAND} // a second fault while reporting kills it at once
	posix.sigemptyset(&act.sa_mask)
	for sig in ([]posix.Signal{.SIGSEGV, .SIGBUS, .SIGILL, .SIGFPE, .SIGABRT, .SIGTRAP}) {
		posix.sigaction(sig, &act, nil)
	}
}

@(private)
crash_signal :: proc "c" (sig: posix.Signal) {
	cause := "a fatal signal"
	#partial switch sig {
	case .SIGSEGV: cause = "SIGSEGV (a bad memory access)"
	case .SIGBUS:  cause = "SIGBUS (a bad memory access)"
	case .SIGILL:  cause = "SIGILL (a trap: a failed assertion or bounds check)"
	case .SIGTRAP: cause = "SIGTRAP (a trap: a failed assertion or bounds check)"
	case .SIGFPE:  cause = "SIGFPE (an arithmetic fault)"
	case .SIGABRT: cause = "SIGABRT (aborted)"
	}
	crash_report(cause)
	// The default action, so the exit status says what it was. (Set by hand:
	// RESETHAND doesn't hold for every signal everywhere, and a trap
	// returned to would trap again, round and round.)
	dfl: posix.sigaction_t
	dfl.sa_handler = auto_cast posix.SIG_DFL
	posix.sigemptyset(&dfl.sa_mask)
	posix.sigaction(sig, &dfl, nil)
	unblock: posix.sigset_t
	posix.sigemptyset(&unblock)
	posix.sigaddset(&unblock, sig)
	posix.pthread_sigmask(.UNBLOCK, &unblock, nil)
	posix.raise(sig)
	posix._exit(128 + i32(sig))
}
