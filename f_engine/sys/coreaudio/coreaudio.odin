#+build darwin
// Raw CoreAudio HAL bindings: only what fire:backend/coreaudio uses. No logic.
// Layouts checked against the macOS SDK (see tests/coreaudio).
package coreaudio_sys

import CF "core:sys/darwin/CoreFoundation"
import "core:sys/posix"

foreign import CoreAudio "system:CoreAudio.framework"

OSStatus           :: i32
Boolean            :: u8
AudioObjectID      :: u32
AudioDeviceIOProcID :: rawptr

NO_ERR :: OSStatus(0)

AudioObjectPropertyAddress :: struct {
	mSelector: u32,
	mScope:    u32,
	mElement:  u32,
}

SMPTETime :: struct {
	mSubframes:       i16,
	mSubframeDivisor: i16,
	mCounter:         u32,
	mType:            u32,
	mFlags:           u32,
	mHours:           i16,
	mMinutes:         i16,
	mSeconds:         i16,
	mFrames:          i16,
}

AudioTimeStamp_Flag :: enum u32 {
	Sample_Time_Valid     = 0,
	Host_Time_Valid       = 1,
	Rate_Scalar_Valid     = 2,
	Word_Clock_Time_Valid = 3,
	SMPTE_Time_Valid      = 4,
}
AudioTimeStamp_Flags :: bit_set[AudioTimeStamp_Flag; u32]

AudioTimeStamp :: struct {
	mSampleTime:    f64,
	mHostTime:      u64,
	mRateScalar:    f64,
	mWordClockTime: u64,
	mSMPTETime:     SMPTETime,
	mFlags:         AudioTimeStamp_Flags,
	mReserved:      u32,
}

AudioBuffer :: struct {
	mNumberChannels: u32,
	mDataByteSize:   u32,
	mData:           rawptr,
}

// Variable length: mBuffers really has mNumberBuffers entries.
AudioBufferList :: struct {
	mNumberBuffers: u32,
	mBuffers:       [1]AudioBuffer,
}

audio_buffer_list_buffers :: #force_inline proc "contextless" (l: ^AudioBufferList) -> []AudioBuffer {
	return ([^]AudioBuffer)(&l.mBuffers)[:l.mNumberBuffers]
}

AudioValueRange :: struct {
	mMinimum: f64,
	mMaximum: f64,
}

AudioDeviceIOProc :: #type proc "c" (
	inDevice: AudioObjectID,
	inNow: ^AudioTimeStamp,
	inInputData: ^AudioBufferList,
	inInputTime: ^AudioTimeStamp,
	outOutputData: ^AudioBufferList,
	inOutputTime: ^AudioTimeStamp,
	inClientData: rawptr,
) -> OSStatus

AudioObjectPropertyListenerProc :: #type proc "c" (
	inObjectID: AudioObjectID,
	inNumberAddresses: u32,
	inAddresses: [^]AudioObjectPropertyAddress,
	inClientData: rawptr,
) -> OSStatus

@(default_calling_convention = "c")
foreign CoreAudio {
	AudioObjectHasProperty :: proc(inObjectID: AudioObjectID, inAddress: ^AudioObjectPropertyAddress) -> Boolean ---
	AudioObjectIsPropertySettable :: proc(inObjectID: AudioObjectID, inAddress: ^AudioObjectPropertyAddress, outIsSettable: ^Boolean) -> OSStatus ---
	AudioObjectGetPropertyDataSize :: proc(inObjectID: AudioObjectID, inAddress: ^AudioObjectPropertyAddress, inQualifierDataSize: u32, inQualifierData: rawptr, outDataSize: ^u32) -> OSStatus ---
	AudioObjectGetPropertyData :: proc(inObjectID: AudioObjectID, inAddress: ^AudioObjectPropertyAddress, inQualifierDataSize: u32, inQualifierData: rawptr, ioDataSize: ^u32, outData: rawptr) -> OSStatus ---
	AudioObjectSetPropertyData :: proc(inObjectID: AudioObjectID, inAddress: ^AudioObjectPropertyAddress, inQualifierDataSize: u32, inQualifierData: rawptr, inDataSize: u32, inData: rawptr) -> OSStatus ---
	AudioObjectAddPropertyListener :: proc(inObjectID: AudioObjectID, inAddress: ^AudioObjectPropertyAddress, inListener: AudioObjectPropertyListenerProc, inClientData: rawptr) -> OSStatus ---
	AudioObjectRemovePropertyListener :: proc(inObjectID: AudioObjectID, inAddress: ^AudioObjectPropertyAddress, inListener: AudioObjectPropertyListenerProc, inClientData: rawptr) -> OSStatus ---

	AudioDeviceCreateIOProcID :: proc(inDevice: AudioObjectID, inProc: AudioDeviceIOProc, inClientData: rawptr, outIOProcID: ^AudioDeviceIOProcID) -> OSStatus ---
	AudioDeviceDestroyIOProcID :: proc(inDevice: AudioObjectID, inIOProcID: AudioDeviceIOProcID) -> OSStatus ---
	AudioDeviceStart :: proc(inDevice: AudioObjectID, inProcID: AudioDeviceIOProcID) -> OSStatus ---
	AudioDeviceStop :: proc(inDevice: AudioObjectID, inProcID: AudioDeviceIOProcID) -> OSStatus ---

	AudioGetCurrentHostTime :: proc() -> u64 ---
	AudioConvertHostTimeToNanos :: proc(inHostTime: u64) -> u64 ---
	AudioConvertNanosToHostTime :: proc(inNanos: u64) -> u64 ---
}

CFStringRef :: CF.String

// --- constants (four-char codes) -----------------------------------------------

kAudioObjectSystemObject :: AudioObjectID(1)
kAudioObjectUnknown      :: AudioObjectID(0)

kAudioObjectPropertyScopeGlobal :: u32('g') << 24 | u32('l') << 16 | u32('o') << 8 | u32('b')
kAudioObjectPropertyScopeInput  :: u32('i') << 24 | u32('n') << 16 | u32('p') << 8 | u32('t')
kAudioObjectPropertyScopeOutput :: u32('o') << 24 | u32('u') << 16 | u32('t') << 8 | u32('p')
kAudioObjectPropertyElementMain :: u32(0)

kAudioObjectPropertyName :: u32('l') << 24 | u32('n') << 16 | u32('a') << 8 | u32('m')
// A channel's name: the property in a scope, its element the channel (1-based).
kAudioObjectPropertyElementName :: u32('l') << 24 | u32('c') << 16 | u32('h') << 8 | u32('n')

kAudioHardwarePropertyDevices              :: u32('d') << 24 | u32('e') << 16 | u32('v') << 8 | u32('#')
kAudioHardwarePropertyDefaultInputDevice   :: u32('d') << 24 | u32('I') << 16 | u32('n') << 8 | u32(' ')
kAudioHardwarePropertyDefaultOutputDevice  :: u32('d') << 24 | u32('O') << 16 | u32('u') << 8 | u32('t')
kAudioHardwarePropertyRunLoop              :: u32('r') << 24 | u32('n') << 16 | u32('l') << 8 | u32('p')

kAudioDevicePropertyDeviceUID                 :: u32('u') << 24 | u32('i') << 16 | u32('d') << 8 | u32(' ')
kAudioDevicePropertyDeviceIsAlive             :: u32('l') << 24 | u32('i') << 16 | u32('v') << 8 | u32('n')
kAudioDevicePropertyStreamConfiguration       :: u32('s') << 24 | u32('l') << 16 | u32('a') << 8 | u32('y')
kAudioDevicePropertyNominalSampleRate         :: u32('n') << 24 | u32('s') << 16 | u32('r') << 8 | u32('t')
kAudioDevicePropertyAvailableNominalSampleRates :: u32('n') << 24 | u32('s') << 16 | u32('r') << 8 | u32('#')
kAudioDevicePropertyBufferFrameSize           :: u32('f') << 24 | u32('s') << 16 | u32('i') << 8 | u32('z')
kAudioDevicePropertyBufferFrameSizeRange      :: u32('f') << 24 | u32('s') << 16 | u32('z') << 8 | u32('#')
kAudioDevicePropertyLatency                   :: u32('l') << 24 | u32('t') << 16 | u32('n') << 8 | u32('c')
kAudioDevicePropertySafetyOffset              :: u32('s') << 24 | u32('a') << 16 | u32('f') << 8 | u32('t')
kAudioDevicePropertyStreams                   :: u32('s') << 24 | u32('t') << 16 | u32('m') << 8 | u32('#')
kAudioDeviceProcessorOverload                 :: u32('o') << 24 | u32('v') << 16 | u32('e') << 8 | u32('r')
kAudioDevicePropertyVolumeScalar              :: u32('v') << 24 | u32('o') << 16 | u32('l') << 8 | u32('m')
kAudioStreamPropertyLatency                   :: kAudioDevicePropertyLatency

// --- aggregate devices ---------------------------------------------------------------

@(default_calling_convention = "c")
foreign CoreAudio {
	// Makes an aggregate device from a description (the keys below); its
	// id in `outDeviceID`. A private one is unseen by other apps and goes
	// when the process does.
	AudioHardwareCreateAggregateDevice :: proc(inDescription: CF.TypeRef, outDeviceID: ^AudioObjectID) -> OSStatus ---
	AudioHardwareDestroyAggregateDevice :: proc(inDeviceID: AudioObjectID) -> OSStatus ---
}

// An aggregate's description: keys (CFStrings).
kAudioAggregateDeviceUIDKey          :: "uid"
kAudioAggregateDeviceNameKey         :: "name"
kAudioAggregateDeviceIsPrivateKey    :: "private"
kAudioAggregateDeviceIsStackedKey    :: "stacked"
kAudioAggregateDeviceSubDeviceListKey :: "subdevices"
kAudioAggregateDeviceMainSubDeviceKey :: "master" // the clock
// A sub-device's description.
kAudioSubDeviceUIDKey                :: "uid"
kAudioSubDeviceDriftCompensationKey  :: "drift"

// --- CoreFoundation (what an aggregate's description needs) --------------------------

foreign import CoreFoundation "system:CoreFoundation.framework"

CFIndex :: CF.Index
CFDictionaryRef :: distinct rawptr
CFArrayRef      :: distinct rawptr
CFNumberRef     :: distinct rawptr

// CoreFoundation's own callbacks for dictionaries and arrays of CF objects
// (kCFTypeDictionaryKeyCallBacks, ...): their addresses, looked up when
// first needed (data symbols, so not foreign variables: those don't link
// at every optimization level).
cf_callbacks :: proc(name: cstring) -> rawptr {
	RTLD_DEFAULT :: posix.Symbol_Table(uintptr(~uintptr(1))) // ((void*)-2 on macOS: every loaded image)
	return posix.dlsym(RTLD_DEFAULT, name)
}

// CFNumberType: a 32-bit signed integer.
kCFNumberSInt32Type :: CF.Index(3)
// CFStringEncoding: UTF-8.
kCFStringEncodingUTF8 :: u32(0x08000100)

@(default_calling_convention = "c")
foreign CoreFoundation {
	CFDictionaryCreateMutable :: proc(allocator: rawptr, capacity: CFIndex, keyCallBacks: rawptr, valueCallBacks: rawptr) -> CFDictionaryRef ---
	CFDictionarySetValue :: proc(theDict: CFDictionaryRef, key: rawptr, value: rawptr) ---
	CFArrayCreateMutable :: proc(allocator: rawptr, capacity: CFIndex, callBacks: rawptr) -> CFArrayRef ---
	CFArrayAppendValue :: proc(theArray: CFArrayRef, value: rawptr) ---
	CFNumberCreate :: proc(allocator: rawptr, theType: CFIndex, valuePtr: rawptr) -> CFNumberRef ---
	CFStringCreateWithCString :: proc(alloc: rawptr, cStr: cstring, encoding: u32) -> CFStringRef ---
}
