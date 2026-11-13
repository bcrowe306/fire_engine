package test_synth

import "core:testing"

import "fire:core"
import "fire:synth"

// A Sync LFO follows the song's timeline, not the clock's grid: a note
// played at beat 0.25 of the sequence has its phase there (a cycle a
// beat), and after a stop and play from the top, the next block it is at
// the top again, whatever the grid did meanwhile.
@(test)
a_sync_lfo_follows_the_sequencer :: proc(t: ^testing.T) {
	r := rig_synth()
	defer rig_synth_free(r)
	id := core.Timeline_Id{index = 0, generation = 1}
	r.s.timeline = id
	set_param(r, synth.lfo_param(1, .Mode), f32(int(synth.Lfo_Mode.Sync)))
	set_param(r, synth.lfo_param(1, .Rate), f32(int(synth.Lfo_Rate.Tempo)))
	set_param(r, synth.lfo_param(1, .Tempo), 8) // 1/4: a cycle a beat
	synth.patch_add_route(&r.patch, {source = .Lfo_1, dest = synth.filter_param(1, .Cutoff), amount = 0.2})
	synth.synth_set_patch(r.s, &r.patch)
	N :: 256
	core.node_prepare(&r.node, {sample_rate = SR, max_block = N, out_channels = 2})
	outs := [2][]f32{make([]f32, N, context.temp_allocator), make([]f32, N, context.temp_allocator)}
	timelines := []core.Timeline_State{{id = id, playing = true, position = 0.25, rate = 1}}
	tr := core.Transport{sample_rate = SR, grid = 7.6, tempo_bpm = 120, timelines = timelines}
	block :: proc(r: ^Synth_Rig, tr: ^core.Transport, outs: ^[2][]f32, events: []core.Event) {
		ctx := core.Process_Context{outputs = outs[:], frames = N, events_in = events, transport = tr}
		core.node_process(&r.node, &ctx)
	}
	block(r, &tr, &outs, {{offset = 0, payload = core.Note_On{id = core.NOTE_ID_ANY, key = 60, velocity = 1}}})
	step := f32(N) / f32(SR) * 2 // (a block: this much of a beat at 120)
	ph := synth.synth_live(r.s).lfo_phase[0]
	testing.expectf(t, abs(ph - (0.25 + step)) < 0.02, "where the sequence is: %v (the grid's would be %v)", ph, 0.6 + step)
	// Stopped a while (the grid runs on), then played from the top: the
	// held note's LFO is back at the top.
	timelines[0].position = 0
	tr.grid = 31.3
	block(r, &tr, &outs, nil)
	ph = synth.synth_live(r.s).lfo_phase[0]
	testing.expectf(t, ph < step + 0.02 || ph > 0.98, "back at the top with the sequence: %v", ph)
}
