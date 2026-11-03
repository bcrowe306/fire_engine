#+build windows
// Raw WinMM MIDI bindings (mmeapi.h): only what fire:midi/winmm uses. No logic.
package winmm_sys

foreign import winmm "system:Winmm.lib"

MMRESULT :: u32
HMIDIIN  :: distinct rawptr
HMIDIOUT :: distinct rawptr

MMSYSERR_NOERROR :: MMRESULT(0)
MIDIERR_STILLPLAYING :: MMRESULT(65)

CALLBACK_NULL     :: u32(0x00000000)
CALLBACK_FUNCTION :: u32(0x00030000)
MIDI_IO_STATUS    :: u32(0x00000020)

MIM_OPEN      :: u32(0x3C1)
MIM_CLOSE     :: u32(0x3C2)
MIM_DATA      :: u32(0x3C3)
MIM_LONGDATA  :: u32(0x3C4)
MIM_ERROR     :: u32(0x3C5)
MIM_LONGERROR :: u32(0x3C6)
MIM_MOREDATA  :: u32(0x3CC)

MHDR_DONE     :: u32(0x00000001)
MHDR_PREPARED :: u32(0x00000002)

MAXPNAMELEN :: 32

// 120 bytes on 64-bit Windows.
MIDIHDR :: struct {
	lpData:          [^]u8,
	dwBufferLength:  u32,
	dwBytesRecorded: u32,
	dwUser:          uintptr,
	dwFlags:         u32,
	lpNext:          ^MIDIHDR,
	reserved:        uintptr,
	dwOffset:        u32,
	dwReserved:      [8]uintptr,
}

MIDIINCAPSW :: struct #packed {
	wMid:           u16,
	wPid:           u16,
	vDriverVersion: u32,
	szPname:        [MAXPNAMELEN]u16,
	dwSupport:      u32,
}

MIDIOUTCAPSW :: struct #packed {
	wMid:           u16,
	wPid:           u16,
	vDriverVersion: u32,
	szPname:        [MAXPNAMELEN]u16,
	wTechnology:    u16,
	wVoices:        u16,
	wNotes:         u16,
	wChannelMask:   u16,
	dwSupport:      u32,
}

// Called on a WinMM thread. Only a few system calls are allowed inside
// (no blocking, no other midi* calls except midiInAddBuffer in practice).
MIDIINPROC :: #type proc "system" (h: HMIDIIN, msg: u32, instance: uintptr, param1: uintptr, param2: uintptr)

@(default_calling_convention = "system")
foreign winmm {
	midiInGetNumDevs :: proc() -> u32 ---
	midiInGetDevCapsW :: proc(device: uintptr, caps: ^MIDIINCAPSW, size: u32) -> MMRESULT ---
	midiInOpen :: proc(h: ^HMIDIIN, device: u32, callback: uintptr, instance: uintptr, flags: u32) -> MMRESULT ---
	midiInClose :: proc(h: HMIDIIN) -> MMRESULT ---
	midiInStart :: proc(h: HMIDIIN) -> MMRESULT ---
	midiInStop :: proc(h: HMIDIIN) -> MMRESULT ---
	midiInReset :: proc(h: HMIDIIN) -> MMRESULT ---
	midiInPrepareHeader :: proc(h: HMIDIIN, hdr: ^MIDIHDR, size: u32) -> MMRESULT ---
	midiInUnprepareHeader :: proc(h: HMIDIIN, hdr: ^MIDIHDR, size: u32) -> MMRESULT ---
	midiInAddBuffer :: proc(h: HMIDIIN, hdr: ^MIDIHDR, size: u32) -> MMRESULT ---

	midiOutGetNumDevs :: proc() -> u32 ---
	midiOutGetDevCapsW :: proc(device: uintptr, caps: ^MIDIOUTCAPSW, size: u32) -> MMRESULT ---
	midiOutOpen :: proc(h: ^HMIDIOUT, device: u32, callback: uintptr, instance: uintptr, flags: u32) -> MMRESULT ---
	midiOutClose :: proc(h: HMIDIOUT) -> MMRESULT ---
	midiOutReset :: proc(h: HMIDIOUT) -> MMRESULT ---
	midiOutShortMsg :: proc(h: HMIDIOUT, msg: u32) -> MMRESULT ---
	midiOutLongMsg :: proc(h: HMIDIOUT, hdr: ^MIDIHDR, size: u32) -> MMRESULT ---
	midiOutPrepareHeader :: proc(h: HMIDIOUT, hdr: ^MIDIHDR, size: u32) -> MMRESULT ---
	midiOutUnprepareHeader :: proc(h: HMIDIOUT, hdr: ^MIDIHDR, size: u32) -> MMRESULT ---
}
