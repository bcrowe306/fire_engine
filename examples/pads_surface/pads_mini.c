// A control surface for Pads, in C: "Pads Mini". It asks fire:surface's
// host for the Pads API ("fire.pads", version 1) and drives Pads through
// its function table:
//
//   notes 36..51   play pads 0..15 (velocity from the note's)
//   note 94        play / stop
//   CC 14          the tempo: 60 + the value (BPM)
//   CC 15          pad 0's fader: -60..+6 dB
//
// It subscribes to the transport: when it starts or stops, the play LED
// (note 94) follows, and the tempo goes back out as CC 14 (the BPM - 60).
//
// Build it as a shared library against the two headers (scripts/surface.sh
// does: .build/surface/pads_mini.*) and start Pads with
// `--surface .build/surface/pads_mini.dylib`.
//
// SPDX-License-Identifier: MIT (a surface that only uses the API may have
// any licence: see apps/pads/LICENSE-EXCEPTION)
#include "../../f_engine/surface/fire_surface.h"
#include "../../apps/pads/api/include/pads_api.h"

#include <stddef.h>
#include <stdlib.h>

typedef struct {
	fire_surface surface;
	fire_surface_host *host;
	const Pads_Api_V1 *pads;
	Pads_Subscription transport;
	bool playing;
} mini_t;

static void send3(mini_t *m, uint8_t a, uint8_t b, uint8_t c) {
	uint8_t msg[3] = {a, b, c};
	m->host->send_midi(m->host, 0, msg, 3);
}

// The transport changed: the play LED and the tempo go out.
static void on_transport(Pads_Api *api, Pads_Topic topic, int64_t index, void *user) {
	(void)topic;
	(void)index;
	mini_t *m = user;
	Pads_Transport_State t;
	if (m->pads->transport_state(api, &t) != PADS_RESULT_OK) return;
	m->playing = t.playing;
	send3(m, 0x90, 94, t.playing ? 127 : 0);
	double bpm = t.bpm - 60;
	send3(m, 0xB0, 14, (uint8_t)(bpm < 0 ? 0 : bpm > 127 ? 127 : bpm + 0.5));
}

static void on_midi(fire_surface *s, uint32_t port, const uint8_t *b, uint32_t n) {
	(void)port;
	mini_t *m = s->data;
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

static void destroy(fire_surface *s) {
	mini_t *m = s->data;
	if (m->transport) m->pads->unsubscribe(m->pads->api, m->transport); // (what a surface subscribes, it unsubscribes)
	free(m);
}

static fire_surface *create(fire_surface_host *host) {
	if (host->abi_version < 2) return NULL; // (get_extension came with version 2)
	const Pads_Api_V1 *pads = host->get_extension(host, PADS_API_NAME, PADS_API_VERSION);
	// The table only grows: check it has the last function this surface uses.
	if (!pads || pads->size < (int64_t)(offsetof(Pads_Api_V1, unsubscribe) + sizeof(pads->unsubscribe))) {
		host->log(host, 2, "Pads Mini: this host has no Pads API");
		return NULL;
	}
	mini_t *m = calloc(1, sizeof(mini_t));
	m->host = host;
	m->pads = pads;
	m->surface = (fire_surface){.data = m, .destroy = destroy, .on_midi = on_midi};
	if (pads->subscribe(pads->api, PADS_TOPIC_TRANSPORT, -1, on_transport, m, &m->transport) != PADS_RESULT_OK) {
		free(m);
		return NULL;
	}
	host->log(host, 1, "Pads Mini started");
	return &m->surface;
}

static const char *const hints[] = {"Pads Mini", NULL};

static const fire_surface_descriptor mini = {FIRE_SURFACE_ABI_VERSION, "dev.fire-engine.example.pads-mini", "Pads Mini", "Fire Engine", hints, hints, create};

FIRE_SURFACE_EXPORT const fire_surface_descriptor *fire_surface_entry(uint32_t index) { return index == 0 ? &mini : NULL; }
