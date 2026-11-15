// A control surface for Pads, in C: "Pads Mini", a fire-surface library
// (a .fsurf: extern/fire-surface/include/fsurf.h). Pads starts it when a
// MIDI port named "Pads Mini..." is there. It asks its host for the Pads
// API ("fire.pads", version 1) and drives Pads through its function table:
//
//   notes 36..51   play pads 0..15 (velocity from the note's)
//   note 94        play / stop
//   CC 14          the tempo: 60 + the value (BPM)
//   CC 15          pad 0's fader: -60..+6 dB
//
// Those are its (its claim table): the engine never sees them; anything
// else from the controller (a keyboard's keys) plays as usual.
//
// It subscribes to the transport: when it starts or stops, the play LED
// (note 94) follows, and the tempo goes back out as CC 14 (the BPM - 60).
//
// Build it as a shared library named .fsurf (scripts/surface.sh does:
// .build/surface/pads_mini.fsurf) and put it in Pads' Surfaces folder, or
// start Pads with `--surface .build/surface/pads_mini.fsurf`.
//
// SPDX-License-Identifier: MIT (a surface that only uses the API may have
// any licence: see apps/pads/LICENSE-EXCEPTION)
#include "../../extern/fire-surface/include/fsurf.h"
#include "../../apps/pads/api/include/pads_api.h"

#include <stddef.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
	fsurf_surface_t surface;
	const fsurf_host_t *host;
	const Pads_Api_V1 *pads;
	Pads_Subscription transport;
	uint32_t out; // its output port, while active
} mini_t;

static void send3(mini_t *m, uint8_t a, uint8_t b, uint8_t c) {
	uint8_t msg[3] = {a, b, c};
	if (m->out != FSURF_NO_PORT) m->host->send_midi(m->host, m->out, msg, 3);
}

// The transport changed: the play LED and the tempo go out.
static void on_transport(Pads_Api *api, Pads_Topic topic, int64_t index, void *user) {
	(void)topic;
	(void)index;
	mini_t *m = user;
	Pads_Transport_State t;
	if (m->pads->transport_state(api, &t) != PADS_RESULT_OK) return;
	send3(m, 0x90, 94, t.playing ? 127 : 0);
	double bpm = t.bpm - 60;
	send3(m, 0xB0, 14, (uint8_t)(bpm < 0 ? 0 : bpm > 127 ? 127 : bpm + 0.5));
}

// What comes to it: what its claim table takes.
static void on_midi(const fsurf_surface_t *s, uint32_t port, const uint8_t *b, uint32_t n, uint64_t time_ns) {
	(void)port;
	(void)time_ns;
	mini_t *m = s->surface_data;
	const Pads_Api_V1 *p = m->pads;
	if (n != 3) return;
	uint8_t kind = b[0] & 0xF0;
	if ((kind == 0x90 || kind == 0x80) && b[1] >= 36 && b[1] < 52) {
		bool on = kind == 0x90 && b[2] > 0;
		p->pad_play(p->api, b[1] - 36, on, on ? b[2] / 127.0f : 1.0f);
	} else if (kind == 0x90 && b[1] == 94 && b[2] > 0) {
		p->transport_toggle(p->api);
	} else if (kind == 0xB0 && b[1] == 14) {
		p->transport_set_tempo(p->api, 60.0 + b[2]);
	} else if (kind == 0xB0 && b[1] == 15) {
		p->pad_set_volume(p->api, 0, (float)(-60.0 + b[2] * 66.0 / 127.0));
	}
}

static const fsurf_rule_t rules[] = {
	{.port = FSURF_NO_PORT, .messages = FSURF_MSG_NOTES, .first = 36, .end = 52, .action = FSURF_RULE_CLAIM},
	{.port = FSURF_NO_PORT, .messages = FSURF_MSG_NOTES, .first = 94, .end = 95, .action = FSURF_RULE_CLAIM},
	{.port = FSURF_NO_PORT, .messages = FSURF_MSG_CONTROL, .first = 14, .end = 16, .action = FSURF_RULE_CLAIM},
};

static bool activate(const fsurf_surface_t *s, const fsurf_port_t *ports, uint32_t count) {
	mini_t *m = s->surface_data;
	if (count != 1) return false;
	m->out = ports[0].output;
	if (!m->host->set_rules(m->host, rules, sizeof rules / sizeof rules[0])) return false;
	on_transport(m->pads->api, PADS_TOPIC_TRANSPORT, -1, m); // its lights as things are
	return true;
}

static void deactivate(const fsurf_surface_t *s) {
	mini_t *m = s->surface_data;
	send3(m, 0x90, 94, 0);
	m->out = FSURF_NO_PORT;
}

static bool init(const fsurf_surface_t *s) {
	mini_t *m = s->surface_data;
	const Pads_Api_V1 *pads = m->host->get_extension(m->host, PADS_API_NAME, PADS_API_VERSION);
	// The table only grows: check it has the last function this surface uses.
	if (!pads || pads->size < (int64_t)(offsetof(Pads_Api_V1, unsubscribe) + sizeof(pads->unsubscribe))) {
		m->host->log(m->host, FSURF_LOG_WARNING, "Pads Mini: this host has no Pads API");
		return false;
	}
	m->pads = pads;
	if (pads->subscribe(pads->api, PADS_TOPIC_TRANSPORT, -1, on_transport, m, &m->transport) != PADS_RESULT_OK) return false;
	m->host->log(m->host, FSURF_LOG_INFO, "Pads Mini started");
	return true;
}

static void destroy(const fsurf_surface_t *s) {
	mini_t *m = s->surface_data;
	if (m->transport) m->pads->unsubscribe(m->pads->api, m->transport); // (what a surface subscribes, it unsubscribes)
	free(m);
}

static const char *const names[] = {"Pads Mini*", NULL};
static const fsurf_port_spec_t ports[] = {{
	.struct_size = sizeof(fsurf_port_spec_t), .role = "main",
	.flags = FSURF_PORT_INPUT | FSURF_PORT_OUTPUT, .input_names = names, .output_names = names,
}};
static const char *const needs[] = {PADS_API_NAME, NULL};
static const fsurf_descriptor_t mini = {
	.struct_size = sizeof(fsurf_descriptor_t), .fsurf_version = FSURF_VERSION_INIT,
	.id = "dev.fire-engine.example.pads-mini", .name = "Pads Mini", .vendor = "Fire Engine", .version = "2.0",
	.description = "Plays Pads' pads and its transport", .ports = ports, .port_count = 1,
	.required_extensions = needs,
};

static uint32_t factory_count(const fsurf_surface_factory_t *f) { (void)f; return 1; }
static const fsurf_descriptor_t *factory_descriptor(const fsurf_surface_factory_t *f, uint32_t i) { (void)f; return i == 0 ? &mini : NULL; }
static const fsurf_surface_t *factory_create(const fsurf_surface_factory_t *f, const fsurf_host_t *host, const char *id) {
	(void)f;
	if (strcmp(id, mini.id) != 0 || !fsurf_version_is_compatible(host->fsurf_version)) return NULL;
	mini_t *m = calloc(1, sizeof(mini_t));
	if (!m) return NULL;
	m->host = host;
	m->out = FSURF_NO_PORT;
	m->surface = (fsurf_surface_t){
		.struct_size = sizeof(fsurf_surface_t), .desc = &mini, .surface_data = m,
		.init = init, .destroy = destroy, .activate = activate, .deactivate = deactivate, .on_midi = on_midi,
	};
	return &m->surface;
}
static const fsurf_surface_factory_t factory = {factory_count, factory_descriptor, factory_create};

static bool entry_init(const char *path) { (void)path; return true; }
static void entry_deinit(void) {}
static const void *entry_factory(const char *id) { return strcmp(id, FSURF_SURFACE_FACTORY_ID) == 0 ? &factory : NULL; }

FSURF_EXPORT const fsurf_entry_t fsurf_entry = {FSURF_VERSION_INIT, entry_init, entry_deinit, entry_factory};
