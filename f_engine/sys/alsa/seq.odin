#+build linux
// ALSA sequencer bindings: only what fire:midi/alsa uses. Layouts and
// constants checked against <alsa/asoundlib.h> (see tests/alsa_midi).
package alsa_sys

import "base:intrinsics"
import "core:c"

foreign import asound_seq "system:asound"
foreign import libc "system:c"

snd_seq_t              :: distinct rawptr
snd_seq_client_info_t  :: distinct rawptr
snd_seq_port_info_t    :: distinct rawptr
snd_midi_event_t       :: distinct rawptr

SND_SEQ_OPEN_DUPLEX :: c.int(3)
SND_SEQ_NONBLOCK    :: c.int(1)

SND_SEQ_PORT_CAP_READ       :: c.uint(1 << 0)
SND_SEQ_PORT_CAP_WRITE      :: c.uint(1 << 1)
SND_SEQ_PORT_CAP_SUBS_READ  :: c.uint(1 << 5)
SND_SEQ_PORT_CAP_SUBS_WRITE :: c.uint(1 << 6)
SND_SEQ_PORT_CAP_NO_EXPORT  :: c.uint(1 << 7)

SND_SEQ_PORT_TYPE_MIDI_GENERIC :: c.uint(1 << 1)
SND_SEQ_PORT_TYPE_SOFTWARE     :: c.uint(1 << 17)
SND_SEQ_PORT_TYPE_APPLICATION  :: c.uint(1 << 20)

SND_SEQ_ADDRESS_SUBSCRIBERS :: u8(254)
SND_SEQ_ADDRESS_UNKNOWN     :: u8(253)
SND_SEQ_QUEUE_DIRECT        :: u8(253)
SND_SEQ_CLIENT_SYSTEM       :: c.int(0)

SND_SEQ_EVENT_START :: c.int(30) // queue control
SND_SEQ_EVENT_CLIENT_START :: u8(60)
SND_SEQ_EVENT_CLIENT_EXIT  :: u8(61)
SND_SEQ_EVENT_PORT_START   :: u8(63)
SND_SEQ_EVENT_PORT_EXIT    :: u8(64)
SND_SEQ_EVENT_PORT_CHANGE  :: u8(65)
SND_SEQ_PORT_SYSTEM_ANNOUNCE :: c.int(1)
SND_SEQ_EVENT_SYSEX :: u8(130)

// snd_seq_event_t.flags
SND_SEQ_TIME_STAMP_REAL       :: u8(1 << 0)
SND_SEQ_TIME_MODE_ABS         :: u8(0)
SND_SEQ_EVENT_LENGTH_VARIABLE :: u8(1 << 2)
SND_SEQ_EVENT_LENGTH_MASK     :: u8(3 << 2)

snd_seq_real_time_t :: struct {
	tv_sec:  u32,
	tv_nsec: u32,
}

snd_seq_addr_t :: struct {
	client: u8,
	port:   u8,
}

// 28 bytes, packed. `data` is a union; for variable-length events (SysEx) it
// holds snd_seq_ev_ext_t {len: u32, ptr: rawptr} with the pointer unaligned at
// offset 4 (use ev_ext / ev_set_ext).
snd_seq_event_t :: struct #packed {
	type:   u8,
	flags:  u8,
	tag:    i8,
	queue:  u8,
	time:   snd_seq_real_time_t, // union with a u32 tick time
	source: snd_seq_addr_t,
	dest:   snd_seq_addr_t,
	data:   [12]u8,
}

ev_ext :: proc "contextless" (ev: ^snd_seq_event_t) -> []u8 {
	n := intrinsics.unaligned_load((^u32)(&ev.data[0]))
	p := intrinsics.unaligned_load((^rawptr)(&ev.data[4]))
	return ([^]u8)(p)[:n] if p != nil else nil
}

ev_set_ext :: proc "contextless" (ev: ^snd_seq_event_t, data: []u8) {
	ev.flags = (ev.flags & ~SND_SEQ_EVENT_LENGTH_MASK) | SND_SEQ_EVENT_LENGTH_VARIABLE
	intrinsics.unaligned_store((^u32)(&ev.data[0]), u32(len(data)))
	intrinsics.unaligned_store((^rawptr)(&ev.data[4]), rawptr(raw_data(data)))
}

pollfd :: struct {
	fd:      c.int,
	events:  c.short,
	revents: c.short,
}
POLLIN :: c.short(0x001)

@(default_calling_convention = "c")
foreign asound_seq {
	snd_seq_open :: proc(seq: ^snd_seq_t, name: cstring, streams: c.int, mode: c.int) -> c.int ---
	snd_seq_close :: proc(seq: snd_seq_t) -> c.int ---
	snd_seq_set_client_name :: proc(seq: snd_seq_t, name: cstring) -> c.int ---
	snd_seq_client_id :: proc(seq: snd_seq_t) -> c.int ---
	snd_seq_create_simple_port :: proc(seq: snd_seq_t, name: cstring, caps: c.uint, type: c.uint) -> c.int ---
	snd_seq_delete_simple_port :: proc(seq: snd_seq_t, port: c.int) -> c.int ---
	snd_seq_connect_from :: proc(seq: snd_seq_t, my_port: c.int, src_client: c.int, src_port: c.int) -> c.int ---
	snd_seq_disconnect_from :: proc(seq: snd_seq_t, my_port: c.int, src_client: c.int, src_port: c.int) -> c.int ---
	snd_seq_poll_descriptors_count :: proc(seq: snd_seq_t, events: c.short) -> c.int ---
	snd_seq_poll_descriptors :: proc(seq: snd_seq_t, pfds: [^]pollfd, space: c.uint, events: c.short) -> c.int ---
	snd_seq_event_input :: proc(seq: snd_seq_t, ev: ^^snd_seq_event_t) -> c.int ---
	snd_seq_event_output_direct :: proc(seq: snd_seq_t, ev: ^snd_seq_event_t) -> c.int ---
	snd_seq_alloc_queue :: proc(seq: snd_seq_t) -> c.int ---
	snd_seq_free_queue :: proc(seq: snd_seq_t, q: c.int) -> c.int ---
	snd_seq_control_queue :: proc(seq: snd_seq_t, q: c.int, type: c.int, value: c.int, ev: ^snd_seq_event_t) -> c.int ---
	snd_seq_drain_output :: proc(seq: snd_seq_t) -> c.int ---

	snd_seq_client_info_malloc :: proc(ptr: ^snd_seq_client_info_t) -> c.int ---
	snd_seq_client_info_free :: proc(obj: snd_seq_client_info_t) ---
	snd_seq_client_info_set_client :: proc(info: snd_seq_client_info_t, client: c.int) ---
	snd_seq_client_info_get_client :: proc(info: snd_seq_client_info_t) -> c.int ---
	snd_seq_client_info_get_name :: proc(info: snd_seq_client_info_t) -> cstring ---
	snd_seq_query_next_client :: proc(seq: snd_seq_t, info: snd_seq_client_info_t) -> c.int ---

	snd_seq_port_info_malloc :: proc(ptr: ^snd_seq_port_info_t) -> c.int ---
	snd_seq_port_info_free :: proc(obj: snd_seq_port_info_t) ---
	snd_seq_port_info_set_client :: proc(info: snd_seq_port_info_t, client: c.int) ---
	snd_seq_port_info_set_port :: proc(info: snd_seq_port_info_t, port: c.int) ---
	snd_seq_port_info_get_port :: proc(info: snd_seq_port_info_t) -> c.int ---
	snd_seq_port_info_get_name :: proc(info: snd_seq_port_info_t) -> cstring ---
	snd_seq_port_info_get_capability :: proc(info: snd_seq_port_info_t) -> c.uint ---
	snd_seq_port_info_set_timestamping :: proc(info: snd_seq_port_info_t, enable: c.int) ---
	snd_seq_port_info_set_timestamp_real :: proc(info: snd_seq_port_info_t, enable: c.int) ---
	snd_seq_port_info_set_timestamp_queue :: proc(info: snd_seq_port_info_t, queue: c.int) ---
	snd_seq_query_next_port :: proc(seq: snd_seq_t, info: snd_seq_port_info_t) -> c.int ---
	snd_seq_get_port_info :: proc(seq: snd_seq_t, port: c.int, info: snd_seq_port_info_t) -> c.int ---
	snd_seq_set_port_info :: proc(seq: snd_seq_t, port: c.int, info: snd_seq_port_info_t) -> c.int ---

	snd_midi_event_new :: proc(bufsize: c.size_t, rdev: ^snd_midi_event_t) -> c.int ---
	snd_midi_event_free :: proc(dev: snd_midi_event_t) ---
	snd_midi_event_no_status :: proc(dev: snd_midi_event_t, on: c.int) ---
	snd_midi_event_reset_encode :: proc(dev: snd_midi_event_t) ---
	snd_midi_event_reset_decode :: proc(dev: snd_midi_event_t) ---
	snd_midi_event_encode :: proc(dev: snd_midi_event_t, buf: [^]u8, count: c.long, ev: ^snd_seq_event_t) -> c.long ---
	snd_midi_event_decode :: proc(dev: snd_midi_event_t, buf: [^]u8, count: c.long, ev: ^snd_seq_event_t) -> c.long ---
}

@(default_calling_convention = "c")
foreign libc {
	poll :: proc(fds: [^]pollfd, nfds: c.ulong, timeout_ms: c.int) -> c.int ---
}
