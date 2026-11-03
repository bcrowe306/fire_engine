// MIDI 1.0 messages, their Universal MIDI Packet (UMP) encoding, and helpers.
// Drivers speak UMP (CoreMIDI, Windows MIDI Services) or bytes (ALSA, WinMM);
// the engine works with MIDI 1.0 bytes. See docs/design/backend.md.
package midi

// Length in bytes of a MIDI 1.0 message with this status byte (0 = not a
// complete short message on its own: data byte, SysEx start/end, undefined).
message_length :: proc "contextless" (status: u8) -> int {
	switch {
	case status < 0x80:  return 0
	case status < 0xC0:  return 3 // note off/on, poly pressure, CC
	case status < 0xE0:  return 2 // program change, channel pressure
	case status < 0xF0:  return 3 // pitch bend
	}
	switch status {
	case 0xF1, 0xF3:                         return 2 // MTC quarter frame, song select
	case 0xF2:                               return 3 // song position
	case 0xF6, 0xF8, 0xFA, 0xFB, 0xFC, 0xFE, 0xFF: return 1
	}
	return 0 // F0/F7 (SysEx), F4/F5/F9/FD (undefined)
}

// UMP message type → words per packet (UMP spec 1.1, table 4).
ump_word_count :: proc "contextless" (first_word: u32) -> int {
	@(static, rodata) counts := [16]u8{1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4}
	return int(counts[first_word >> 28])
}

UMP_SYSTEM      :: 0x1
UMP_MIDI1_VOICE :: 0x2
UMP_DATA64      :: 0x3 // SysEx 7-bit

Sysex_Status :: enum u8 {
	Complete = 0,
	Start    = 1,
	Continue = 2,
	End      = 3,
}

// Encodes a MIDI 1.0 short message as one UMP word. ok = false for SysEx or
// invalid status bytes.
ump_from_short :: proc "contextless" (bytes: [3]u8, group: u8 = 0) -> (word: u32, ok: bool) {
	n := message_length(bytes[0])
	if n == 0 do return 0, false
	mt := u32(UMP_SYSTEM if bytes[0] >= 0xF0 else UMP_MIDI1_VOICE)
	word = mt << 28 | u32(group & 0xF) << 24 | u32(bytes[0]) << 16
	if n >= 2 do word |= u32(bytes[1] & 0x7F) << 8
	if n >= 3 do word |= u32(bytes[2] & 0x7F)
	return word, true
}

// Decodes a type 1 or type 2 UMP word into MIDI 1.0 bytes.
ump_to_short :: proc "contextless" (word: u32) -> (bytes: [3]u8, ok: bool) {
	mt := word >> 28
	if mt != UMP_SYSTEM && mt != UMP_MIDI1_VOICE do return {}, false
	bytes = {u8(word >> 16), u8(word >> 8) & 0x7F, u8(word) & 0x7F}
	n := message_length(bytes[0])
	if n == 0 do return {}, false
	if n < 3 do bytes[2] = 0
	if n < 2 do bytes[1] = 0
	return bytes, true
}

// Number of 2-word packets needed for a SysEx payload (without F0/F7).
ump_sysex_packet_count :: proc "contextless" (payload_len: int) -> int {
	return max(1, (payload_len + 5) / 6)
}

// Encodes one SysEx packet (index `i` of the payload) into two UMP words.
ump_sysex_packet :: proc "contextless" (payload: []u8, i: int, group: u8 = 0) -> [2]u32 {
	count := ump_sysex_packet_count(len(payload))
	status := Sysex_Status.Complete
	if count > 1 {
		status = .Start if i == 0 else (.End if i == count - 1 else .Continue)
	}
	chunk := payload[min(i * 6, len(payload)):min(i * 6 + 6, len(payload))]
	b: [6]u8
	for v, k in chunk do b[k] = v & 0x7F
	w0 := u32(UMP_DATA64) << 28 | u32(group & 0xF) << 24 | u32(status) << 20 | u32(len(chunk)) << 16 | u32(b[0]) << 8 | u32(b[1])
	w1 := u32(b[2]) << 24 | u32(b[3]) << 16 | u32(b[4]) << 8 | u32(b[5])
	return {w0, w1}
}

// Reassembles SysEx from UMP data64 packets for one source. The buffer is
// preallocated; a message longer than it is dropped (and counted).
Sysex_Assembler :: struct {
	buffer:     []u8,
	len:        int,
	active:     bool,
	overflowed: bool,
}

Sysex_Result :: enum u8 {
	None,      // more packets needed (or nothing to do)
	Complete,  // `assembler_message` holds a complete payload
	Dropped,   // message too long or malformed; discarded
}

// [rt]-safe: no allocation. `words` is one data64 packet.
sysex_assemble :: proc "contextless" (a: ^Sysex_Assembler, words: [2]u32) -> Sysex_Result {
	status := Sysex_Status((words[0] >> 20) & 0xF)
	count := int((words[0] >> 16) & 0xF)
	if count > 6 do count = 6
	b := [6]u8{u8(words[0] >> 8), u8(words[0]), u8(words[1] >> 24), u8(words[1] >> 16), u8(words[1] >> 8), u8(words[1])}

	switch status {
	case .Complete, .Start:
		if a.active && status == .Start {
			a.active = false // previous message never ended
		}
		a.len = 0
		a.overflowed = false
		a.active = true
	case .Continue, .End:
		if !a.active do return .Dropped
	case:
		a.active = false
		return .Dropped
	}
	for v in b[:count] {
		if a.len < len(a.buffer) {
			a.buffer[a.len] = v & 0x7F
			a.len += 1
		} else {
			a.overflowed = true
		}
	}
	if status == .Complete || status == .End {
		a.active = false
		return .Dropped if a.overflowed else .Complete
	}
	return .None
}

assembler_message :: proc "contextless" (a: ^Sysex_Assembler) -> []u8 {
	return a.buffer[:a.len]
}
