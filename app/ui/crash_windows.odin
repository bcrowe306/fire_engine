#+build windows
package ui

import win "core:sys/windows"

@(private)
_crash_install :: proc() {
	win.SetUnhandledExceptionFilter(crash_exception)
}

@(private)
crash_exception :: proc "system" (info: ^win.EXCEPTION_POINTERS) -> win.LONG {
	cause := "an unhandled exception"
	if info != nil && info.ExceptionRecord != nil {
		switch info.ExceptionRecord.ExceptionCode {
		case win.EXCEPTION_ACCESS_VIOLATION:      cause = "EXCEPTION_ACCESS_VIOLATION (a bad memory access)"
		case win.EXCEPTION_ILLEGAL_INSTRUCTION:   cause = "EXCEPTION_ILLEGAL_INSTRUCTION (a trap: a failed assertion or bounds check)"
		case win.EXCEPTION_INT_DIVIDE_BY_ZERO:    cause = "EXCEPTION_INT_DIVIDE_BY_ZERO"
		case win.EXCEPTION_STACK_OVERFLOW:        cause = "EXCEPTION_STACK_OVERFLOW"
		case win.EXCEPTION_BREAKPOINT:            cause = "EXCEPTION_BREAKPOINT (a trap)"
		}
	}
	crash_report(cause)
	return win.EXCEPTION_CONTINUE_SEARCH
}
