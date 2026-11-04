/*
Recording: audio takes written to disk, MIDI and automation recorded into
clips, and loop recording, all placed on a timeline.

- An `Audio_Recorder` is a graph node: connect any signal to its inputs
  (the device input, a bus, a track to resample). While armed and its
  timeline plays, it copies what arrives into blocks that a
  `Disk_Writer` thread writes as WAV takes. Finished takes come back from
  `audio_recorder_poll` with their timeline position, ready to become
  audio clips.
- A `Midi_Recorder` records the events it receives into MIDI clips, one
  per take; `midi_recorder_progress` shows the take so far, for
  overdubbing as you play.
- An `Automation_Recorder` passes the app's control moves on to a node
  and writes them into automation (touch or latch); merge the ranges into
  a lane with `clip.automation_merge`.
- **Latency.** A performer plays along with output they hear late, and
  their signal reaches the recorder later again. Recorders shift what
  they record by `latency_frames`, the round trip: use
  `backend.round_trip_latency_frames` once the device runs, or measure it
  with a `Latency_Probe` and a loopback cable.
- **Punch in and out** limit recording to a range of the timeline.
- **Loop recording.** When the timeline wraps while recording, the take
  ends and the next pass starts a new one, so every pass is kept.

	disk, _ := record.disk_writer_create({})
	defer record.disk_writer_destroy(disk)
	node, rec, _ := record.audio_recorder_create(disk, {timeline = song, channels = 2, directory = "takes", name = "vocal"})
	id, _ := graph.add_node(g, node, 2, 0)
	graph.connect(g, graph.INPUT, 0, id, 0)
	graph.connect(g, graph.INPUT, 1, id, 1)
	graph.commit(g)
	// once the device runs:
	record.audio_recorder_set_latency(rec, backend.round_trip_latency_frames(&dev))
	record.audio_recorder_arm(rec, true)
	// ... play the song; then, regularly:
	for take in record.audio_recorder_poll(rec) do use(take) // a clip of take.path, placed at take.start

See /guides/recording/ for more.
*/
package record

import "base:intrinsics"
import "core:mem"
import "core:sync"
import "core:thread"
import "core:time"

import "fire:core"

// Settings for `disk_writer_create`.
Disk_Writer_Settings :: struct {
	// No thread: the app calls `disk_writer_service` to write, for example
	// once per block in an offline render, so nothing is ever dropped.
	manual: bool,
}

// Writes the takes of any number of audio recorders on one background
// thread. Control thread only. Fields are internal.
Disk_Writer :: struct {
	settings:  Disk_Writer_Settings,
	allocator: mem.Allocator,
	lock:      sync.Mutex, // guards `recorders` and every recorder's disk side
	recorders: [dynamic]^Audio_Recorder,
	thread:    ^thread.Thread,
	running:   bool, // atomic
}

// How long the idle disk thread sleeps. A 4 s buffer leaves plenty of room.
@(private)
IDLE :: 2 * time.Millisecond

// Control thread. Starts the disk thread (unless `manual`). Free with
// `disk_writer_destroy`, after the recorders using it.
disk_writer_create :: proc(settings: Disk_Writer_Settings, allocator := context.allocator) -> (d: ^Disk_Writer, err: core.Error) {
	d = new(Disk_Writer, allocator)
	if d == nil do return nil, .Out_Of_Memory
	d.settings, d.allocator = settings, allocator
	d.recorders = make([dynamic]^Audio_Recorder, allocator)
	if settings.manual do return d, .None
	intrinsics.atomic_store(&d.running, true)
	d.thread = thread.create_and_start_with_data(d, proc(data: rawptr) {
		d := (^Disk_Writer)(data)
		for intrinsics.atomic_load(&d.running) do if !disk_writer_service(d) do time.sleep(IDLE)
	})
	if d.thread == nil {
		disk_writer_destroy(d)
		return nil, .Out_Of_Memory
	}
	return d, .None
}

// Control thread. Stops the disk thread. Recorders still registered stop
// being served.
disk_writer_destroy :: proc(d: ^Disk_Writer) {
	if d == nil do return
	intrinsics.atomic_store(&d.running, false)
	if d.thread != nil {
		thread.join(d.thread)
		thread.destroy(d.thread)
	}
	delete(d.recorders)
	free(d, d.allocator)
}

// Writes everything the recorders have queued. Returns whether there was
// anything to do. The disk thread calls it; in `manual` mode, the app does
// (any thread but the audio thread).
disk_writer_service :: proc(d: ^Disk_Writer) -> bool {
	sync.guard(&d.lock)
	worked := false
	for r in d.recorders do worked |= serve(r)
	return worked
}
