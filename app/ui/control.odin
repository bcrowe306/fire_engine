package ui

import "core:fmt"
import "core:net"
import "core:strings"

// Live control of a running app, for a test harness: a TCP server on
// 127.0.0.1 taking drive-script commands, one per line, and answering
// each with one line of JSON once it has run (its frames waited, its
// events delivered):
//
//	{"ok": true, "output": "…what the command said…"}
//	{"ok": false, "error": "…why it failed…", "output": "…"}
//
// One client at a time; the next connects when it leaves. Commands run
// through the app's `Driver` (live), so everything a script can do, a
// connection can.
Control :: struct {
	listener: net.TCP_Socket,
	client:   net.TCP_Socket,
	has_client: bool,
	inbuf:    [dynamic]u8,
	busy:     bool, // a line is running: its answer goes when the driver is idle
	port:     int,
}

// Starts listening on 127.0.0.1:`port` (0: any free port; `c.port` says
// which). False if it can't.
control_open :: proc(c: ^Control, port: int) -> bool {
	ep := net.Endpoint{address = net.IP4_Loopback, port = port}
	sock, err := net.listen_tcp(ep, 4)
	if err != nil {
		fmt.eprintfln("ui: control: cannot listen on port %d: %v", port, err)
		return false
	}
	net.set_blocking(sock, false)
	c.listener = sock
	c.port = port
	if bound, berr := net.bound_endpoint(sock); berr == nil do c.port = bound.port
	c.inbuf = make([dynamic]u8)
	return true
}

// Stops listening (and drops the client).
control_close :: proc(c: ^Control) {
	if c.has_client do net.close(c.client)
	net.close(c.listener)
	delete(c.inbuf)
	c^ = {}
}

// Once a frame, before the driver steps: takes a client, and gives the
// driver the next line (one at a time) when it has finished the last;
// answers the last when it has.
@(private)
control_poll :: proc(c: ^Control, d: ^Driver) {
	if !c.has_client {
		client, _, err := net.accept_tcp(c.listener)
		if err != nil do return
		net.set_blocking(client, false)
		c.client, c.has_client = client, true
		clear(&c.inbuf)
		c.busy = false
	}
	// The answer to the line that has run.
	if c.busy && driver_idle(d) {
		control_answer(c, d)
		c.busy = false
	}
	// Read what came.
	buf: [4096]u8
	for {
		n, err := net.recv_tcp(c.client, buf[:])
		if err != nil {
			if err == .Would_Block do break
			control_drop(c)
			return
		}
		if n == 0 {
			control_drop(c) // closed
			return
		}
		append(&c.inbuf, ..buf[:n])
	}
	// The next line, if the last has been answered.
	if !c.busy {
		if i := index_of_newline(c.inbuf[:]); i >= 0 {
			line := strings.trim_space(string(c.inbuf[:i]))
			l := strings.clone(line, context.temp_allocator)
			remove_range(&c.inbuf, 0, i + 1)
			if l != "" {
				driver_feed(d, l)
				c.busy = true
			}
		}
	}
}

@(private)
index_of_newline :: proc(b: []u8) -> int {
	for x, i in b do if x == '\n' do return i
	return -1
}

@(private)
control_drop :: proc(c: ^Control) {
	net.close(c.client)
	c.has_client, c.busy = false, false
	clear(&c.inbuf)
}

// One line of JSON: whether the line worked, what it said, and why not.
@(private)
control_answer :: proc(c: ^Control, d: ^Driver) {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `{"ok": `)
	strings.write_string(&sb, "true" if d.error == "" else "false")
	if d.error != "" {
		strings.write_string(&sb, `, "error": `)
		json_string(&sb, d.error)
	}
	strings.write_string(&sb, `, "output": `)
	json_string(&sb, strings.to_string(d.reply))
	strings.write_string(&sb, "}\n")
	out := sb.buf[:]
	for len(out) > 0 {
		n, err := net.send_tcp(c.client, out)
		if err != nil {
			if err == .Would_Block do continue
			control_drop(c)
			return
		}
		out = out[n:]
	}
}

// `s` as a JSON string.
@(private)
json_string :: proc(sb: ^strings.Builder, s: string) {
	strings.write_byte(sb, '"')
	for r in s {
		switch r {
		case '"':  strings.write_string(sb, `\"`)
		case '\\': strings.write_string(sb, `\\`)
		case '\n': strings.write_string(sb, `\n`)
		case '\t': strings.write_string(sb, `\t`)
		case '\r': strings.write_string(sb, `\r`)
		case:
			if r < 0x20 do fmt.sbprintf(sb, `\u%04x`, int(r))
			else do strings.write_rune(sb, r)
		}
	}
	strings.write_byte(sb, '"')
}
