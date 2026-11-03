package testkit

import "base:runtime"
import "core:mem"

// An allocator that refuses every request and records it. Installed as both
// context.allocator and context.temp_allocator around each `process` call, so any
// allocation on the audio thread fails the test, along with its call site.
Trap_Allocator :: struct {
	violations: int,
	first_loc:  runtime.Source_Code_Location,
	first_mode: mem.Allocator_Mode,
}

// An allocator backed by `t`: every request except feature queries and free(nil)
// fails with .Out_Of_Memory and is counted in `t.violations`. Install it as
// context.allocator around code that must not allocate (for example a device callback).
trap_allocator :: proc(t: ^Trap_Allocator) -> mem.Allocator {
	return mem.Allocator{procedure = trap_allocator_proc, data = t}
}

@(private)
trap_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	t := (^Trap_Allocator)(allocator_data)
	#partial switch mode {
	case .Query_Features, .Query_Info:
		return nil, .Mode_Not_Implemented
	case .Free:
		if old_memory == nil do return nil, .None // free(nil) is harmless
	case .Free_All:
		// Odin's runtime may call free_all on the temp allocator; resetting
		// nothing is harmless, but a node doing it is still suspicious.
	}
	if t.violations == 0 {
		t.first_loc = location
		t.first_mode = mode
	}
	t.violations += 1
	return nil, .Out_Of_Memory
}
