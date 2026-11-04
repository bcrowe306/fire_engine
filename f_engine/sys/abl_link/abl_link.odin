// Raw bindings to Ableton Link's C wrapper (abl_link.h): only what fire:link
// uses. No logic. The library is built by scripts/link.sh into
// third_party/link/lib; Link is GPLv2+ unless you hold Ableton's licence.
package abl_link_sys

when ODIN_OS == .Windows {
	foreign import abl {
		"../../../third_party/link/lib/abl_link.lib",
		"system:ws2_32.lib",
		"system:iphlpapi.lib",
		"system:winmm.lib",
	}
} else when ODIN_OS == .Darwin {
	foreign import abl {
		"../../../third_party/link/lib/libabl_link.a",
		"system:c++",
	}
} else {
	foreign import abl {
		"../../../third_party/link/lib/libabl_link.a",
		"system:stdc++",
		"system:pthread",
	}
}

// One Link instance (`struct abl_link`).
Link :: struct {
	impl: rawptr,
}

// A captured session state (`abl_link_session_state`).
Session_State :: struct {
	impl: rawptr,
}

@(default_calling_convention = "c", link_prefix = "abl_link_")
foreign abl {
	create                       :: proc(bpm: f64) -> Link ---
	destroy                      :: proc(link: Link) ---
	is_enabled                   :: proc(link: Link) -> bool ---
	enable                       :: proc(link: Link, enable: bool) ---
	num_peers                    :: proc(link: Link) -> u64 ---
	clock_micros                 :: proc(link: Link) -> i64 ---
	create_session_state         :: proc() -> Session_State ---
	destroy_session_state        :: proc(state: Session_State) ---
	capture_audio_session_state  :: proc(link: Link, state: Session_State) ---
	commit_audio_session_state   :: proc(link: Link, state: Session_State) ---
	capture_app_session_state    :: proc(link: Link, state: Session_State) ---
	commit_app_session_state     :: proc(link: Link, state: Session_State) ---
	tempo                        :: proc(state: Session_State) -> f64 ---
	set_tempo                    :: proc(state: Session_State, bpm: f64, at_time: i64) ---
	beat_at_time                 :: proc(state: Session_State, time: i64, quantum: f64) -> f64 ---
	phase_at_time                :: proc(state: Session_State, time: i64, quantum: f64) -> f64 ---
	time_at_beat                 :: proc(state: Session_State, beat: f64, quantum: f64) -> i64 ---
	request_beat_at_time         :: proc(state: Session_State, beat: f64, time: i64, quantum: f64) ---
	is_start_stop_sync_enabled   :: proc(link: Link) -> bool ---
	enable_start_stop_sync       :: proc(link: Link, enabled: bool) ---
	set_is_playing               :: proc(state: Session_State, is_playing: bool, time: i64) ---
	is_playing                   :: proc(state: Session_State) -> bool ---
	time_for_is_playing          :: proc(state: Session_State) -> i64 ---
}
