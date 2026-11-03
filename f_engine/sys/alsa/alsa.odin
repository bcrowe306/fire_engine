#+build linux
// Raw ALSA (libasound) bindings: only what fire:backend/alsa uses. No logic.
// Constants checked against <alsa/asoundlib.h> (see tests/alsa).
package alsa_sys

import "core:c"

foreign import asound "system:asound"

snd_pcm_t             :: distinct rawptr
snd_pcm_hw_params_t   :: distinct rawptr
snd_pcm_sw_params_t   :: distinct rawptr
snd_ctl_t             :: distinct rawptr
snd_ctl_card_info_t   :: distinct rawptr
snd_pcm_info_t        :: distinct rawptr
snd_pcm_uframes_t     :: c.ulong
snd_pcm_sframes_t     :: c.long

snd_pcm_stream_t :: enum c.int {
	PLAYBACK = 0,
	CAPTURE  = 1,
}

snd_pcm_access_t :: enum c.int {
	MMAP_INTERLEAVED    = 0,
	MMAP_NONINTERLEAVED = 1,
	MMAP_COMPLEX        = 2,
	RW_INTERLEAVED      = 3,
	RW_NONINTERLEAVED   = 4,
}

snd_pcm_format_t :: enum c.int {
	UNKNOWN    = -1,
	S16_LE     = 2,
	S24_LE     = 6,  // 24 bits in the low bytes of 32
	S32_LE     = 10,
	FLOAT_LE   = 14,
	FLOAT64_LE = 16,
	S24_3LE    = 32, // packed 3 bytes
}

snd_pcm_state_t :: enum c.int {
	OPEN         = 0,
	SETUP        = 1,
	PREPARED     = 2,
	RUNNING      = 3,
	XRUN         = 4,
	DRAINING     = 5,
	PAUSED       = 6,
	SUSPENDED    = 7,
	DISCONNECTED = 8,
}

SND_PCM_NONBLOCK :: c.int(0x1)

// errno values ALSA returns negated.
EAGAIN   :: 11
ENODEV   :: 19
EPIPE    :: 32
EBADFD   :: 77
ESTRPIPE :: 86

@(default_calling_convention = "c")
foreign asound {
	snd_strerror :: proc(errnum: c.int) -> cstring ---

	snd_pcm_open :: proc(pcm: ^snd_pcm_t, name: cstring, stream: snd_pcm_stream_t, mode: c.int) -> c.int ---
	snd_pcm_close :: proc(pcm: snd_pcm_t) -> c.int ---
	snd_pcm_prepare :: proc(pcm: snd_pcm_t) -> c.int ---
	snd_pcm_start :: proc(pcm: snd_pcm_t) -> c.int ---
	snd_pcm_drop :: proc(pcm: snd_pcm_t) -> c.int ---
	snd_pcm_link :: proc(pcm1, pcm2: snd_pcm_t) -> c.int ---
	snd_pcm_unlink :: proc(pcm: snd_pcm_t) -> c.int ---
	snd_pcm_state :: proc(pcm: snd_pcm_t) -> snd_pcm_state_t ---
	snd_pcm_recover :: proc(pcm: snd_pcm_t, err: c.int, silent: c.int) -> c.int ---
	snd_pcm_delay :: proc(pcm: snd_pcm_t, delayp: ^snd_pcm_sframes_t) -> c.int ---
	snd_pcm_avail :: proc(pcm: snd_pcm_t) -> snd_pcm_sframes_t ---
	snd_pcm_wait :: proc(pcm: snd_pcm_t, timeout_ms: c.int) -> c.int ---
	snd_pcm_readi :: proc(pcm: snd_pcm_t, buffer: rawptr, size: snd_pcm_uframes_t) -> snd_pcm_sframes_t ---
	snd_pcm_writei :: proc(pcm: snd_pcm_t, buffer: rawptr, size: snd_pcm_uframes_t) -> snd_pcm_sframes_t ---
	snd_pcm_readn :: proc(pcm: snd_pcm_t, bufs: [^]rawptr, size: snd_pcm_uframes_t) -> snd_pcm_sframes_t ---
	snd_pcm_writen :: proc(pcm: snd_pcm_t, bufs: [^]rawptr, size: snd_pcm_uframes_t) -> snd_pcm_sframes_t ---

	snd_pcm_hw_params_malloc :: proc(ptr: ^snd_pcm_hw_params_t) -> c.int ---
	snd_pcm_hw_params_free :: proc(obj: snd_pcm_hw_params_t) ---
	snd_pcm_hw_params_any :: proc(pcm: snd_pcm_t, params: snd_pcm_hw_params_t) -> c.int ---
	snd_pcm_hw_params :: proc(pcm: snd_pcm_t, params: snd_pcm_hw_params_t) -> c.int ---
	snd_pcm_hw_params_set_access :: proc(pcm: snd_pcm_t, params: snd_pcm_hw_params_t, access: snd_pcm_access_t) -> c.int ---
	snd_pcm_hw_params_test_access :: proc(pcm: snd_pcm_t, params: snd_pcm_hw_params_t, access: snd_pcm_access_t) -> c.int ---
	snd_pcm_hw_params_set_format :: proc(pcm: snd_pcm_t, params: snd_pcm_hw_params_t, format: snd_pcm_format_t) -> c.int ---
	snd_pcm_hw_params_test_format :: proc(pcm: snd_pcm_t, params: snd_pcm_hw_params_t, format: snd_pcm_format_t) -> c.int ---
	snd_pcm_hw_params_set_channels :: proc(pcm: snd_pcm_t, params: snd_pcm_hw_params_t, val: c.uint) -> c.int ---
	snd_pcm_hw_params_get_channels_max :: proc(params: snd_pcm_hw_params_t, val: ^c.uint) -> c.int ---
	snd_pcm_hw_params_get_channels_min :: proc(params: snd_pcm_hw_params_t, val: ^c.uint) -> c.int ---
	snd_pcm_hw_params_set_rate :: proc(pcm: snd_pcm_t, params: snd_pcm_hw_params_t, val: c.uint, dir: c.int) -> c.int ---
	snd_pcm_hw_params_test_rate :: proc(pcm: snd_pcm_t, params: snd_pcm_hw_params_t, val: c.uint, dir: c.int) -> c.int ---
	snd_pcm_hw_params_set_rate_resample :: proc(pcm: snd_pcm_t, params: snd_pcm_hw_params_t, val: c.uint) -> c.int ---
	snd_pcm_hw_params_set_period_size_near :: proc(pcm: snd_pcm_t, params: snd_pcm_hw_params_t, val: ^snd_pcm_uframes_t, dir: ^c.int) -> c.int ---
	snd_pcm_hw_params_set_periods_near :: proc(pcm: snd_pcm_t, params: snd_pcm_hw_params_t, val: ^c.uint, dir: ^c.int) -> c.int ---
	snd_pcm_hw_params_get_period_size :: proc(params: snd_pcm_hw_params_t, frames: ^snd_pcm_uframes_t, dir: ^c.int) -> c.int ---
	snd_pcm_hw_params_get_period_size_min :: proc(params: snd_pcm_hw_params_t, frames: ^snd_pcm_uframes_t, dir: ^c.int) -> c.int ---
	snd_pcm_hw_params_get_period_size_max :: proc(params: snd_pcm_hw_params_t, frames: ^snd_pcm_uframes_t, dir: ^c.int) -> c.int ---
	snd_pcm_hw_params_get_buffer_size :: proc(params: snd_pcm_hw_params_t, val: ^snd_pcm_uframes_t) -> c.int ---

	snd_pcm_sw_params_malloc :: proc(ptr: ^snd_pcm_sw_params_t) -> c.int ---
	snd_pcm_sw_params_free :: proc(obj: snd_pcm_sw_params_t) ---
	snd_pcm_sw_params_current :: proc(pcm: snd_pcm_t, params: snd_pcm_sw_params_t) -> c.int ---
	snd_pcm_sw_params :: proc(pcm: snd_pcm_t, params: snd_pcm_sw_params_t) -> c.int ---
	snd_pcm_sw_params_set_start_threshold :: proc(pcm: snd_pcm_t, params: snd_pcm_sw_params_t, val: snd_pcm_uframes_t) -> c.int ---
	snd_pcm_sw_params_set_avail_min :: proc(pcm: snd_pcm_t, params: snd_pcm_sw_params_t, val: snd_pcm_uframes_t) -> c.int ---

	snd_card_next :: proc(card: ^c.int) -> c.int ---
	snd_ctl_open :: proc(ctl: ^snd_ctl_t, name: cstring, mode: c.int) -> c.int ---
	snd_ctl_close :: proc(ctl: snd_ctl_t) -> c.int ---
	snd_ctl_card_info_malloc :: proc(ptr: ^snd_ctl_card_info_t) -> c.int ---
	snd_ctl_card_info_free :: proc(obj: snd_ctl_card_info_t) ---
	snd_ctl_card_info :: proc(ctl: snd_ctl_t, info: snd_ctl_card_info_t) -> c.int ---
	snd_ctl_card_info_get_id :: proc(obj: snd_ctl_card_info_t) -> cstring ---
	snd_ctl_card_info_get_name :: proc(obj: snd_ctl_card_info_t) -> cstring ---
	snd_ctl_pcm_next_device :: proc(ctl: snd_ctl_t, device: ^c.int) -> c.int ---
	snd_ctl_pcm_info :: proc(ctl: snd_ctl_t, info: snd_pcm_info_t) -> c.int ---
	snd_pcm_info_malloc :: proc(ptr: ^snd_pcm_info_t) -> c.int ---
	snd_pcm_info_free :: proc(obj: snd_pcm_info_t) ---
	snd_pcm_info_set_device :: proc(obj: snd_pcm_info_t, val: c.uint) ---
	snd_pcm_info_set_subdevice :: proc(obj: snd_pcm_info_t, val: c.uint) ---
	snd_pcm_info_set_stream :: proc(obj: snd_pcm_info_t, val: snd_pcm_stream_t) ---
	snd_pcm_info_get_name :: proc(obj: snd_pcm_info_t) -> cstring ---
}
