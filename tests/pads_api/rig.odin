package test_pads_api

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import app "app:core"
import pa "../../apps/pads/api"
import pc "../../apps/pads/core"
import pm "../../apps/pads/model"
import fc "fire:core"
import kit "fire:testkit"

SR :: 48_000.0

// Pads without a window: the core (a project on the fake driver, rendered
// offline) and the API on it.
Rig :: struct {
	core: pc.Core,
	api:  pa.Api,
	dir:  string,
}

rig_make :: proc(t: ^testing.T, name: string) -> ^Rig {
	r := new(Rig)
	c := &r.core
	app.bus_init(&c.bus)
	app.host_init(&c.host, {fake = true, sample_rate = SR, max_block = 256}, &c.bus)
	app.host_open(&c.host) // makes the graph at 48 kHz
	app.host_close(&c.host) // render offline from here
	r.dir, _ = filepath.join({kit.artifacts_root(), "pads_api", name})
	os.remove_all(r.dir)
	for k := 0; k < 100 && !os.is_dir(r.dir); k += 1 do os.make_directory_all(r.dir)
	// Pads' own folders, in the test's.
	c.files.folders.settings, _ = filepath.join({r.dir, "settings"})
	c.files.folders.prefs = strings.clone(c.files.folders.settings)
	c.files.folders.unsaved, _ = filepath.join({r.dir, "Unsaved"})
	os.make_directory_all(c.files.folders.settings)
	testing.expect_value(t, pm.model_init(&c.m, &c.host, r.dir), fc.Error.None)
	testing.expect_value(t, pm.model_new(&c.m, r.dir), fc.Error.None)
	pa.api_init(&r.api, c)
	frame(r) // (subscribers start from here)
	return r
}

rig_destroy :: proc(r: ^Rig) {
	pa.api_destroy(&r.api)
	pm.capture_destroy(&r.core.capture)
	pc.files_destroy(&r.core.files)
	pc.settings_destroy(&r.core)
	pm.model_destroy(&r.core.m)
	app.host_destroy(&r.core.host)
	app.bus_destroy(&r.core.bus)
	delete(r.dir)
	free(r)
}

// One frame of the app: 1/60 s.
frame :: proc(r: ^Rig, dt := 1.0 / 60) {
	pa.api_frame(&r.api, dt)
	pm.sync(&r.core.m.engine)
}

// Renders `frames` of audio offline (the transport moves).
render :: proc(r: ^Rig, frames: int) {
	pm.sync(&r.core.m.engine)
	out := [2][]f32{make([]f32, frames, context.temp_allocator), make([]f32, frames, context.temp_allocator)}
	app.host_render(&r.core.host, out[:], frames, nil)
}
