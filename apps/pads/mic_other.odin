#+build !darwin
package pads

// Whether the system lets Pads take audio from its inputs (see the macOS
// one: elsewhere the system doesn't hold it back this way).
Mic_Access :: enum u8 {
	Unknown,
	Not_Asked,
	Denied,
	Granted,
}

// The microphone permission: always Unknown here (nothing to ask).
mic_access :: proc() -> Mic_Access {
	return .Unknown
}
