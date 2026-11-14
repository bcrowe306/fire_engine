/*
 * Fire Engine control-surface scripts: the ABI, for scripts written in C.
 * The same declarations as fire:surface (abi.odin); see /guides/surfaces/.
 *
 * A script library exports one function, fire_surface_entry, returning its
 * surfaces by index (NULL past the last). Every call happens on the app's
 * control thread.
 *
 * MIT licence, as Fire Engine.
 */
#ifndef FIRE_SURFACE_H
#define FIRE_SURFACE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define FIRE_SURFACE_ABI_VERSION 2 /* 2 added get_extension; a host loads 1 and 2 */

#if defined(_WIN32)
#define FIRE_SURFACE_EXPORT __declspec(dllexport)
#else
#define FIRE_SURFACE_EXPORT __attribute__((visibility("default")))
#endif

typedef struct fire_surface_host fire_surface_host;
typedef struct fire_surface fire_surface;

/* The transport, as a surface sees it. */
typedef struct fire_transport_state {
	bool playing;
	bool looping;
	double position; /* beats, on the surface's timeline */
	double tempo_bpm;
	int64_t bar; /* 0-based, on the clock's bar grid */
	double loop_start;
	double loop_end;
	int32_t numerator;
	int32_t denominator;
} fire_transport_state;

/* What a control is. */
enum {
	FIRE_CONTROL_CONTINUOUS = 0, /* a knob or fader: min..max */
	FIRE_CONTROL_TOGGLE = 1,     /* on (max) or off (min) */
	FIRE_CONTROL_TRIGGER = 2,    /* fires when set to max */
	FIRE_CONTROL_STEPPED = 3,    /* `steps` values from min to max */
};

/* A control the app publishes. Strings belong to the host. */
typedef struct fire_control_info {
	uint32_t id;
	uint32_t kind;
	const char *name;
	const char *group;
	double min;
	double max;
	double default_value;
	uint32_t steps;
} fire_control_info;

/* What a surface can do. */
struct fire_surface_host {
	uint32_t abi_version;
	void *data;
	bool (*send_midi)(fire_surface_host *h, uint32_t port, const uint8_t *bytes, uint32_t size);
	void (*play)(fire_surface_host *h);
	void (*stop)(fire_surface_host *h);
	void (*locate)(fire_surface_host *h, double beats);
	void (*set_loop)(fire_surface_host *h, bool on, double start, double end);
	void (*set_tempo)(fire_surface_host *h, double bpm);
	void (*get_transport)(fire_surface_host *h, fire_transport_state *out);
	uint32_t (*control_count)(fire_surface_host *h);
	bool (*control_info)(fire_surface_host *h, uint32_t index, fire_control_info *out);
	bool (*control_get)(fire_surface_host *h, uint32_t id, double *out);
	bool (*control_set)(fire_surface_host *h, uint32_t id, double value);
	bool (*control_touch)(fire_surface_host *h, uint32_t id, bool touched);
	uint64_t (*node_find)(fire_surface_host *h, const char *name); /* 0 = none */
	bool (*param_set)(fire_surface_host *h, uint64_t node, uint32_t param, double value);
	void (*log)(fire_surface_host *h, int32_t level, const char *message);
	/* An app's own API by name and major version ("fire.pads", 1): what the
	   app documents for it (a function table), or NULL. ABI version 2. */
	void *(*get_extension)(fire_surface_host *h, const char *name, uint32_t version);
};

/* A running surface, made by a descriptor's create. Any callback may be NULL. */
struct fire_surface {
	void *data;
	void (*destroy)(fire_surface *s);
	void (*on_midi)(fire_surface *s, uint32_t port, const uint8_t *bytes, uint32_t size);
	void (*on_control)(fire_surface *s, uint32_t id, double value);
	void (*on_controls_changed)(fire_surface *s);
	void (*on_transport)(fire_surface *s, const fire_transport_state *state);
	void (*on_idle)(fire_surface *s);
};

/* One kind of surface a library provides. */
typedef struct fire_surface_descriptor {
	uint32_t abi_version;
	const char *id;
	const char *name;
	const char *vendor;
	const char *const *input_hints;  /* NULL-terminated port-name substrings */
	const char *const *output_hints;
	fire_surface *(*create)(fire_surface_host *host);
} fire_surface_descriptor;

/* The one export: the library's surfaces by index. */
FIRE_SURFACE_EXPORT const fire_surface_descriptor *fire_surface_entry(uint32_t index);

#ifdef __cplusplus
}
#endif

#endif
