#+build darwin
// Raw CoreMIDI bindings (macOS 11+ UMP APIs): only what fire:midi/coremidi
// uses. No logic. Layouts checked against the macOS SDK (see tests/coremidi).
package coremidi_sys

import "base:intrinsics"
import CF "core:sys/darwin/CoreFoundation"

foreign import CoreMIDI "system:CoreMIDI.framework"
foreign import CoreFoundation "system:CoreFoundation.framework"
foreign import System "system:System"

OSStatus        :: i32
MIDIObjectRef   :: u32
MIDIClientRef   :: MIDIObjectRef
MIDIPortRef     :: MIDIObjectRef
MIDIEndpointRef :: MIDIObjectRef
MIDITimeStamp   :: u64 // mach host time; 0 = now
MIDIProtocolID  :: i32
ItemCount       :: uint
ByteCount       :: uint
CFStringRef     :: CF.String

NO_ERR            :: OSStatus(0)
kMIDIProtocol_1_0 :: MIDIProtocolID(1)
kMIDIProtocol_2_0 :: MIDIProtocolID(2)

// The SDK packs these to 4 bytes (#pragma pack(4)); offsets are natural, but
// the packet's size is 268, not 272.
MIDIEventPacket :: struct #packed {
	timeStamp: MIDITimeStamp,
	wordCount: u32,
	words:     [64]u32,
}

MIDIEventList :: struct #packed {
	protocol:   MIDIProtocolID,
	numPackets: u32,
	packet:     [1]MIDIEventPacket,
}

// Packets are variable length: the next starts right after words[wordCount].
event_packet_next :: #force_inline proc "contextless" (p: ^MIDIEventPacket) -> ^MIDIEventPacket {
	return (^MIDIEventPacket)(uintptr(p) + uintptr(offset_of(MIDIEventPacket, words)) + uintptr(p.wordCount) * size_of(u32))
}

// --- Objective-C blocks ----------------------------------------------------------

// A global block literal (Clang block ABI) calling `invoke(block, evtlist,
// srcConnRefCon)`. Flagged global, so CoreMIDI's Block_copy returns it as is:
// it must outlive the port or endpoint it is given to. `user` is ours.
Receive_Block :: struct {
	isa:        rawptr,
	flags:      i32,
	reserved:   i32,
	invoke:     proc "c" (block: ^Receive_Block, evtlist: ^MIDIEventList, src_ref: rawptr),
	descriptor: ^Block_Descriptor,
	user:       rawptr,
}

Block_Descriptor :: struct {
	reserved: uint,
	size:     uint,
}

BLOCK_IS_GLOBAL :: i32(1 << 28)

@(private)
receive_block_descriptor := Block_Descriptor{0, size_of(Receive_Block)}

receive_block_init :: proc "contextless" (b: ^Receive_Block, invoke: proc "c" (block: ^Receive_Block, evtlist: ^MIDIEventList, src_ref: rawptr), user: rawptr) {
	b^ = {
		isa        = &_NSConcreteGlobalBlock,
		flags      = BLOCK_IS_GLOBAL,
		invoke     = invoke,
		descriptor = &receive_block_descriptor,
		user       = user,
	}
}

mach_timebase_info_data_t :: struct {
	numer, denom: u32,
}

@(default_calling_convention = "c")
foreign System {
	_NSConcreteGlobalBlock: intrinsics.objc_class
	mach_timebase_info :: proc(info: ^mach_timebase_info_data_t) -> i32 ---
}

// --- functions -------------------------------------------------------------------

@(default_calling_convention = "c")
foreign CoreMIDI {
	MIDIClientCreate :: proc(name: CFStringRef, notifyProc: rawptr, notifyRefCon: rawptr, outClient: ^MIDIClientRef) -> OSStatus ---
	MIDIClientDispose :: proc(client: MIDIClientRef) -> OSStatus ---

	MIDIInputPortCreateWithProtocol :: proc(client: MIDIClientRef, portName: CFStringRef, protocol: MIDIProtocolID, outPort: ^MIDIPortRef, receiveBlock: ^Receive_Block) -> OSStatus ---
	MIDIOutputPortCreate :: proc(client: MIDIClientRef, portName: CFStringRef, outPort: ^MIDIPortRef) -> OSStatus ---
	MIDIPortConnectSource :: proc(port: MIDIPortRef, source: MIDIEndpointRef, connRefCon: rawptr) -> OSStatus ---
	MIDIPortDisconnectSource :: proc(port: MIDIPortRef, source: MIDIEndpointRef) -> OSStatus ---
	MIDIPortDispose :: proc(port: MIDIPortRef) -> OSStatus ---

	MIDIGetNumberOfSources :: proc() -> ItemCount ---
	MIDIGetSource :: proc(sourceIndex0: ItemCount) -> MIDIEndpointRef ---
	MIDIGetNumberOfDestinations :: proc() -> ItemCount ---
	MIDIGetDestination :: proc(destIndex0: ItemCount) -> MIDIEndpointRef ---

	MIDIObjectGetStringProperty :: proc(obj: MIDIObjectRef, propertyID: CFStringRef, str: ^CFStringRef) -> OSStatus ---
	MIDIObjectGetIntegerProperty :: proc(obj: MIDIObjectRef, propertyID: CFStringRef, outValue: ^i32) -> OSStatus ---

	MIDISourceCreateWithProtocol :: proc(client: MIDIClientRef, name: CFStringRef, protocol: MIDIProtocolID, outSrc: ^MIDIEndpointRef) -> OSStatus ---
	MIDIDestinationCreateWithProtocol :: proc(client: MIDIClientRef, name: CFStringRef, protocol: MIDIProtocolID, outDest: ^MIDIEndpointRef, readBlock: ^Receive_Block) -> OSStatus ---
	MIDIEndpointDispose :: proc(endpt: MIDIEndpointRef) -> OSStatus ---

	MIDIEventListInit :: proc(evtlist: ^MIDIEventList, protocol: MIDIProtocolID) -> ^MIDIEventPacket ---
	MIDIEventListAdd :: proc(evtlist: ^MIDIEventList, listSize: ByteCount, curPacket: ^MIDIEventPacket, time: MIDITimeStamp, wordCount: ItemCount, words: [^]u32) -> ^MIDIEventPacket ---
	MIDISendEventList :: proc(port: MIDIPortRef, dest: MIDIEndpointRef, evtlist: ^MIDIEventList) -> OSStatus ---
	MIDIReceivedEventList :: proc(src: MIDIEndpointRef, evtlist: ^MIDIEventList) -> OSStatus ---

	kMIDIPropertyName:        CFStringRef
	kMIDIPropertyDisplayName: CFStringRef
	kMIDIPropertyUniqueID:    CFStringRef
}

kCFStringEncodingUTF8 :: u32(0x08000100)

@(default_calling_convention = "c")
foreign CoreFoundation {
	CFStringCreateWithBytes :: proc(alloc: rawptr, bytes: [^]u8, numBytes: CF.Index, encoding: u32, isExternalRepresentation: b8) -> CFStringRef ---
}
