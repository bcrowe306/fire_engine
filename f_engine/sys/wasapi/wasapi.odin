#+build windows
// Raw WASAPI / MMDevice COM bindings: only what fire:backend/wasapi uses.
// No logic. Interface layouts follow mmdeviceapi.h and audioclient.h (vtable
// order matters: IUnknown first, then each interface's methods in header order).
package wasapi_sys

import win "core:sys/windows"

foreign import avrt "system:Avrt.lib"

HRESULT :: win.HRESULT
GUID    :: win.GUID
DWORD   :: win.DWORD
UINT    :: u32
HANDLE  :: win.HANDLE
REFERENCE_TIME :: i64 // 100-ns units

S_OK :: HRESULT(0)
S_FALSE :: HRESULT(1)
AUDCLNT_E_DEVICE_INVALIDATED      :: HRESULT(-2004287484) // 0x88890004
AUDCLNT_E_UNSUPPORTED_FORMAT      :: HRESULT(-2004287480) // 0x88890008
AUDCLNT_E_BUFFER_SIZE_NOT_ALIGNED :: HRESULT(-2004287463) // 0x88890019
AUDCLNT_E_DEVICE_IN_USE           :: HRESULT(-2004287478) // 0x8889000A

EDataFlow :: enum u32 {
	eRender  = 0,
	eCapture = 1,
	eAll     = 2,
}

ERole :: enum u32 {
	eConsole        = 0,
	eMultimedia     = 1,
	eCommunications = 2,
}

DEVICE_STATE_ACTIVE :: DWORD(0x1)
STGM_READ           :: DWORD(0)
CLSCTX_ALL          :: DWORD(0x17)

AUDCLNT_SHAREMODE :: enum u32 {
	SHARED    = 0,
	EXCLUSIVE = 1,
}

AUDCLNT_STREAMFLAGS_EVENTCALLBACK :: DWORD(0x00040000)
AUDCLNT_STREAMFLAGS_NOPERSIST     :: DWORD(0x00080000)

AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY :: DWORD(0x1)
AUDCLNT_BUFFERFLAGS_SILENT             :: DWORD(0x2)
AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR    :: DWORD(0x4)

WAVE_FORMAT_PCM        :: u16(0x0001)
WAVE_FORMAT_IEEE_FLOAT :: u16(0x0003)
WAVE_FORMAT_EXTENSIBLE :: u16(0xFFFE)

WAVEFORMATEX :: struct #packed {
	wFormatTag:      u16,
	nChannels:       u16,
	nSamplesPerSec:  u32,
	nAvgBytesPerSec: u32,
	nBlockAlign:     u16,
	wBitsPerSample:  u16,
	cbSize:          u16,
}

WAVEFORMATEXTENSIBLE :: struct #packed {
	Format:              WAVEFORMATEX,
	wValidBitsPerSample: u16,
	dwChannelMask:       u32,
	SubFormat:           GUID,
}

KSDATAFORMAT_SUBTYPE_PCM        := GUID{0x00000001, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}}
KSDATAFORMAT_SUBTYPE_IEEE_FLOAT := GUID{0x00000003, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}}

CLSID_MMDeviceEnumerator := GUID{0xBCDE0395, 0xE52F, 0x467C, {0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E}}
IID_IMMDeviceEnumerator  := GUID{0xA95664D2, 0x9614, 0x4F35, {0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6}}
IID_IAudioClient         := GUID{0x1CB9AD4C, 0xDBFA, 0x4C32, {0xB1, 0x78, 0xC2, 0xF5, 0x68, 0xA7, 0x03, 0xB2}}
IID_IAudioClient3        := GUID{0x7ED4EE07, 0x8E67, 0x4CD4, {0x8C, 0x1A, 0x2B, 0x7A, 0x59, 0x87, 0xAD, 0x42}}
IID_IAudioRenderClient   := GUID{0xF294ACFC, 0x3146, 0x4483, {0xA7, 0xBF, 0xAD, 0xDC, 0xA7, 0xC2, 0x60, 0xE2}}
IID_IAudioCaptureClient  := GUID{0xC8ADBD64, 0xE71E, 0x48A0, {0xA4, 0xDE, 0x18, 0x5C, 0x39, 0x5C, 0xD3, 0x17}}

PROPERTYKEY :: struct {
	fmtid: GUID,
	pid:   DWORD,
}

PKEY_Device_FriendlyName := PROPERTYKEY{{0xA45C254E, 0xDF1C, 0x4EFD, {0x80, 0x20, 0x67, 0xD1, 0x46, 0xA8, 0x50, 0xE0}}, 14}
PKEY_Device_ContainerId  := PROPERTYKEY{{0x8C7ED206, 0x3F8A, 0x4827, {0xB3, 0xAB, 0xAE, 0x9E, 0x1F, 0xAE, 0xFC, 0x6C}}, 2}

VT_LPWSTR :: u16(31)
VT_CLSID  :: u16(72)

// 24 bytes on 64-bit Windows; `data[0]` holds the pointer for VT_LPWSTR / VT_CLSID.
PROPVARIANT :: struct {
	vt:       u16,
	reserved: [3]u16,
	data:     [2]u64,
}

// --- interfaces ---------------------------------------------------------------------

IUnknown_VTable :: struct {
	QueryInterface: proc "system" (this: rawptr, riid: ^GUID, out: ^rawptr) -> HRESULT,
	AddRef:         proc "system" (this: rawptr) -> u32,
	Release:        proc "system" (this: rawptr) -> u32,
}

IMMDeviceEnumerator :: struct { vtbl: ^IMMDeviceEnumerator_VTable }
IMMDeviceEnumerator_VTable :: struct {
	using _: IUnknown_VTable,
	EnumAudioEndpoints:      proc "system" (this: ^IMMDeviceEnumerator, flow: EDataFlow, state_mask: DWORD, out: ^^IMMDeviceCollection) -> HRESULT,
	GetDefaultAudioEndpoint: proc "system" (this: ^IMMDeviceEnumerator, flow: EDataFlow, role: ERole, out: ^^IMMDevice) -> HRESULT,
	GetDevice:               proc "system" (this: ^IMMDeviceEnumerator, id: win.wstring, out: ^^IMMDevice) -> HRESULT,
	RegisterEndpointNotificationCallback:   proc "system" (this: ^IMMDeviceEnumerator, client: rawptr) -> HRESULT,
	UnregisterEndpointNotificationCallback: proc "system" (this: ^IMMDeviceEnumerator, client: rawptr) -> HRESULT,
}

IMMDeviceCollection :: struct { vtbl: ^IMMDeviceCollection_VTable }
IMMDeviceCollection_VTable :: struct {
	using _: IUnknown_VTable,
	GetCount: proc "system" (this: ^IMMDeviceCollection, count: ^UINT) -> HRESULT,
	Item:     proc "system" (this: ^IMMDeviceCollection, i: UINT, out: ^^IMMDevice) -> HRESULT,
}

IMMDevice :: struct { vtbl: ^IMMDevice_VTable }
IMMDevice_VTable :: struct {
	using _: IUnknown_VTable,
	Activate:          proc "system" (this: ^IMMDevice, iid: ^GUID, clsctx: DWORD, params: rawptr, out: ^rawptr) -> HRESULT,
	OpenPropertyStore: proc "system" (this: ^IMMDevice, access: DWORD, out: ^^IPropertyStore) -> HRESULT,
	GetId:             proc "system" (this: ^IMMDevice, out: ^win.wstring) -> HRESULT,
	GetState:          proc "system" (this: ^IMMDevice, state: ^DWORD) -> HRESULT,
}

IPropertyStore :: struct { vtbl: ^IPropertyStore_VTable }
IPropertyStore_VTable :: struct {
	using _: IUnknown_VTable,
	GetCount: proc "system" (this: ^IPropertyStore, count: ^DWORD) -> HRESULT,
	GetAt:    proc "system" (this: ^IPropertyStore, i: DWORD, key: ^PROPERTYKEY) -> HRESULT,
	GetValue: proc "system" (this: ^IPropertyStore, key: ^PROPERTYKEY, value: ^PROPVARIANT) -> HRESULT,
	SetValue: proc "system" (this: ^IPropertyStore, key: ^PROPERTYKEY, value: ^PROPVARIANT) -> HRESULT,
	Commit:   proc "system" (this: ^IPropertyStore) -> HRESULT,
}

// IAudioClient3 extends IAudioClient2 extends IAudioClient; the vtable holds all three.
IAudioClient :: struct { vtbl: ^IAudioClient_VTable }
IAudioClient_VTable :: struct {
	using _: IUnknown_VTable,
	Initialize:        proc "system" (this: ^IAudioClient, mode: AUDCLNT_SHAREMODE, flags: DWORD, buffer_duration: REFERENCE_TIME, periodicity: REFERENCE_TIME, format: ^WAVEFORMATEX, session: ^GUID) -> HRESULT,
	GetBufferSize:     proc "system" (this: ^IAudioClient, frames: ^UINT) -> HRESULT,
	GetStreamLatency:  proc "system" (this: ^IAudioClient, latency: ^REFERENCE_TIME) -> HRESULT,
	GetCurrentPadding: proc "system" (this: ^IAudioClient, frames: ^UINT) -> HRESULT,
	IsFormatSupported: proc "system" (this: ^IAudioClient, mode: AUDCLNT_SHAREMODE, format: ^WAVEFORMATEX, closest: ^^WAVEFORMATEX) -> HRESULT,
	GetMixFormat:      proc "system" (this: ^IAudioClient, format: ^^WAVEFORMATEX) -> HRESULT,
	GetDevicePeriod:   proc "system" (this: ^IAudioClient, default_period, min_period: ^REFERENCE_TIME) -> HRESULT,
	Start:             proc "system" (this: ^IAudioClient) -> HRESULT,
	Stop:              proc "system" (this: ^IAudioClient) -> HRESULT,
	Reset:             proc "system" (this: ^IAudioClient) -> HRESULT,
	SetEventHandle:    proc "system" (this: ^IAudioClient, event: HANDLE) -> HRESULT,
	GetService:        proc "system" (this: ^IAudioClient, iid: ^GUID, out: ^rawptr) -> HRESULT,
	// IAudioClient2
	IsOffloadCapable:    rawptr,
	SetClientProperties: rawptr,
	GetBufferSizeLimits: rawptr,
	// IAudioClient3
	GetSharedModeEnginePeriod:        proc "system" (this: ^IAudioClient, format: ^WAVEFORMATEX, default_frames, fundamental_frames, min_frames, max_frames: ^UINT) -> HRESULT,
	GetCurrentSharedModeEnginePeriod: proc "system" (this: ^IAudioClient, format: ^^WAVEFORMATEX, period_frames: ^UINT) -> HRESULT,
	InitializeSharedAudioStream:      proc "system" (this: ^IAudioClient, flags: DWORD, period_frames: UINT, format: ^WAVEFORMATEX, session: ^GUID) -> HRESULT,
}

IAudioRenderClient :: struct { vtbl: ^IAudioRenderClient_VTable }
IAudioRenderClient_VTable :: struct {
	using _: IUnknown_VTable,
	GetBuffer:     proc "system" (this: ^IAudioRenderClient, frames: UINT, data: ^[^]u8) -> HRESULT,
	ReleaseBuffer: proc "system" (this: ^IAudioRenderClient, frames: UINT, flags: DWORD) -> HRESULT,
}

IAudioCaptureClient :: struct { vtbl: ^IAudioCaptureClient_VTable }
IAudioCaptureClient_VTable :: struct {
	using _: IUnknown_VTable,
	GetBuffer:         proc "system" (this: ^IAudioCaptureClient, data: ^[^]u8, frames: ^UINT, flags: ^DWORD, device_position: ^u64, qpc_position: ^u64) -> HRESULT,
	ReleaseBuffer:     proc "system" (this: ^IAudioCaptureClient, frames: UINT) -> HRESULT,
	GetNextPacketSize: proc "system" (this: ^IAudioCaptureClient, frames: ^UINT) -> HRESULT,
}

IID_IUnknown             := GUID{0x00000000, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}}
IID_IMMNotificationClient := GUID{0x7991EEC9, 0x7E89, 0x4D85, {0x83, 0x90, 0x6C, 0x70, 0x3C, 0xEC, 0x60, 0xC0}}
E_NOINTERFACE :: HRESULT(-2147467262) // 0x80004002

// Implemented by us; the vtable order follows mmdeviceapi.h. A PROPERTYKEY
// passed by value is passed by reference in the 64-bit Windows ABI.
IMMNotificationClient_VTable :: struct {
	using _: IUnknown_VTable,
	OnDeviceStateChanged:   proc "system" (this: rawptr, id: win.wstring, new_state: DWORD) -> HRESULT,
	OnDeviceAdded:          proc "system" (this: rawptr, id: win.wstring) -> HRESULT,
	OnDeviceRemoved:        proc "system" (this: rawptr, id: win.wstring) -> HRESULT,
	OnDefaultDeviceChanged: proc "system" (this: rawptr, flow: EDataFlow, role: ERole, id: win.wstring) -> HRESULT,
	OnPropertyValueChanged: proc "system" (this: rawptr, id: win.wstring, key: ^PROPERTYKEY) -> HRESULT,
}

// Releases any COM interface pointer (IUnknown is first in every vtable).
release :: proc "contextless" (p: rawptr) {
	if p == nil do return
	vtbl := (^^IUnknown_VTable)(p)^
	vtbl.Release(p)
}

@(default_calling_convention = "system")
foreign avrt {
	AvSetMmThreadCharacteristicsW :: proc(task_name: win.wstring, task_index: ^DWORD) -> HANDLE ---
	AvRevertMmThreadCharacteristics :: proc(handle: HANDLE) -> win.BOOL ---
}
