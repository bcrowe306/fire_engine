// A control-surface script for tests/surface, written in C against
// f_engine/surface/fire_surface.h. "Fire Mini": a fader on CC 7 (the
// control with id 1), a knob on CC 16 (the cutoff of the node named
// "filter"), play/stop/rewind on notes 94/93/91, a play LED (note 94) and
// a motorized fader (CC 7 sent back). It answers a SysEx identity request,
// and exports its structs' layouts.
#include "../../../f_engine/surface/fire_surface.h"

#include <stddef.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
	fire_surface surface;
	fire_surface_host *host;
	int idles;
	bool fader_touched;
} mini_t;

static void send3(mini_t *m, uint8_t a, uint8_t b, uint8_t c) {
	uint8_t msg[3] = {a, b, c};
	m->host->send_midi(m->host, 0, msg, 3);
}

static void on_midi(fire_surface *s, uint32_t port, const uint8_t *b, uint32_t n) {
	mini_t *m = s->data;
	fire_surface_host *h = m->host;
	if (n == 3 && b[0] == 0xB0 && b[1] == 7) { // the fader: a gesture around the moves
		if (!m->fader_touched) h->control_touch(h, 1, m->fader_touched = true);
		h->control_set(h, 1, b[2] / 127.0);
	} else if (n == 3 && b[0] == 0xB0 && b[1] == 0x7F && b[2] == 0) { // the fader let go (touch strip)
		if (m->fader_touched) h->control_touch(h, 1, m->fader_touched = false);
	} else if (n == 3 && b[0] == 0xB0 && b[1] == 16) {
		uint64_t node = h->node_find(h, "filter");
		if (node) h->param_set(h, node, 1, 20.0 + b[2] * 100.0);
	} else if (n == 3 && b[0] == 0x90 && b[2] > 0) {
		if (b[1] == 94) h->play(h);
		if (b[1] == 93) h->stop(h);
		if (b[1] == 91) h->locate(h, 0);
	} else if (n == 6 && b[0] == 0xF0 && b[1] == 0x7E && b[3] == 0x06 && b[4] == 0x01 && b[5] == 0xF7) {
		const uint8_t reply[] = {0xF0, 0x7E, 0x00, 0x06, 0x02, 0x7D, 0x01, 0x02, 0x03, 0x04, 0xF7};
		h->send_midi(h, 0, reply, sizeof(reply));
	}
}

static void on_control(fire_surface *s, uint32_t id, double value) {
	if (id == 1) send3(s->data, 0xB0, 7, (uint8_t)(value * 127 + 0.5)); // move the motorized fader
}

static void on_transport(fire_surface *s, const fire_transport_state *t) {
	send3(s->data, 0x90, 94, t->playing ? 127 : 0); // the play LED
}

static void on_idle(fire_surface *s) { ((mini_t *)s->data)->idles++; }

static void destroy(fire_surface *s) { free(s->data); }

static fire_surface *create(fire_surface_host *host) {
	if (host->abi_version != FIRE_SURFACE_ABI_VERSION) return NULL;
	mini_t *m = calloc(1, sizeof(mini_t));
	m->host = host;
	m->surface = (fire_surface){.data = m, .destroy = destroy, .on_midi = on_midi, .on_control = on_control,
		.on_transport = on_transport, .on_idle = on_idle};
	host->log(host, 1, "Fire Mini started");
	return &m->surface;
}

static const char *const in_hints[] = {"Mini", NULL};
static const char *const out_hints[] = {"Mini", NULL};

static const fire_surface_descriptor mini = {FIRE_SURFACE_ABI_VERSION, "dev.fire-engine.test.mini", "Fire Mini", "Fire Engine", in_hints, out_hints, create};

FIRE_SURFACE_EXPORT const fire_surface_descriptor *fire_surface_entry(uint32_t index) { return index == 0 ? &mini : NULL; }

// Layouts, as the C compiler makes them, for the Odin side to compare.
#define S(T) {#T, -1, sizeof(T)}
#define F(T, f) {#T "." #f, 0, offsetof(T, f)}
typedef struct { const char *name; int is_offset; size_t value; } layout_t;
static const layout_t layouts[] = {
	S(fire_transport_state), F(fire_transport_state, position), F(fire_transport_state, bar), F(fire_transport_state, denominator),
	S(fire_control_info), F(fire_control_info, name), F(fire_control_info, default_value), F(fire_control_info, steps),
	S(fire_surface_host), F(fire_surface_host, send_midi), F(fire_surface_host, get_transport), F(fire_surface_host, control_touch), F(fire_surface_host, log),
	S(fire_surface), F(fire_surface, on_idle), S(fire_surface_descriptor), F(fire_surface_descriptor, input_hints), F(fire_surface_descriptor, create),
};
FIRE_SURFACE_EXPORT int fire_surface_layout(int i, const char **name, int *is_offset, uint64_t *value) {
	if (i < 0 || i >= (int)(sizeof(layouts) / sizeof(layouts[0]))) return 0;
	*name = layouts[i].name;
	*is_offset = layouts[i].is_offset == 0;
	*value = layouts[i].value;
	return 1;
}
