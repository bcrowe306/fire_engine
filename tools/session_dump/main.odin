// Prints a saved session (or any chunk tree the engine writes) as text: one
// line per chunk with its tag, version and size, and for the engine's own
// chunks what they hold.
//
//	odin run tools/session_dump -collection:fire=f_engine -- song.fire
package session_dump

import "core:fmt"
import "core:os"

import "fire:core"
import "fire:graph"
import "fire:transport"

main :: proc() {
	if len(os.args) != 2 {
		fmt.eprintln("usage: session_dump FILE")
		os.exit(2)
	}
	data, err := os.read_entire_file(os.args[1], context.allocator)
	if err != nil {
		fmt.eprintfln("cannot read %s: %v", os.args[1], err)
		os.exit(1)
	}
	r := core.state_reader(data)
	if !dump(&r, 0) {
		fmt.eprintln("malformed data at byte", r.pos)
		os.exit(1)
	}
}

// Chunks whose payload is a list of chunks (after the values `prefix` skips).
Container :: struct {
	tag:    core.Tag,
	prefix: int, // bytes of values before the children
}

containers := []Container {
	{{'F', 'S', 'E', 'S'}, 0},
	{graph.GRAPH_TAG, 16},
}

dump :: proc(r: ^core.State_Reader, depth: int) -> bool {
	for !core.reader_done(r) {
		c, ok := core.read_chunk(r)
		if !ok do return r.err == .None
		fmt.printf("%*s%s v%d  %d bytes", depth * 2, "", string(c.tag[:]), c.version, len(c.data))
		cr := core.chunk_reader(c)
		switch c.tag {
		case graph.NODE_TAG:
			index := core.read_u32(&cr)
			type_id := core.read_string(&cr)
			ins, outs := core.read_int(&cr), core.read_int(&cr)
			fmt.printf("  #%d %s  %d in, %d out", index, type_id, ins, outs)
			fmt.println()
			if !dump(&cr, depth + 1) do return false
			continue
		case graph.PARAMS_TAG:
			count := core.read_int(&cr)
			for _ in 0 ..< count do fmt.printf("  %d=%v", core.read_u32(&cr), core.read_f64(&cr))
		case graph.CONNECTIONS_TAG:
			count := core.read_int(&cr)
			fmt.printf("  %d connections", count)
		case transport.CLOCK_TAG:
			fmt.printf("  %v BPM", core.read_f64(&cr))
		}
		fmt.println()
		for k in containers do if k.tag == c.tag {
			sub := core.State_Reader{data = c.data, pos = k.prefix}
			if !dump(&sub, depth + 1) do return false
		}
	}
	return r.err == .None
}
