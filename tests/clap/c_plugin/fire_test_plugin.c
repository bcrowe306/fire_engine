// A small CLAP plug-in written against CLAP's own headers (vendor/clap), to
// test Fire Engine's CLAP host and to check its Odin bindings (fire:sys/clap)
// against the real ABI. Built by scripts/clap.sh.
//
// "dev.fire-engine.test.gain": stereo in and out, a gain parameter (id 7, in
// dB, applied sample-accurately), a 32-frame delay it reports as latency,
// note input echoed to note output an octave up, and state (the gain).
// It counts calls made on the wrong thread, and exports the size and field
// offsets of every CLAP struct the bindings declare.

#include <clap/clap.h>
#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__((visibility("default")))
#endif

#define GAIN_ID 7
#define DELAY 32
#define MAX_FRAMES 8192

typedef struct {
	clap_plugin_t plugin;
	const clap_host_t *host;
	const clap_host_thread_check_t *thread_check;
	double gain_db;
	float ring[2][DELAY];
	int pos;
	int active, processing;
} test_plugin_t;

static int wrong_thread = 0;

EXPORT int fire_test_wrong_thread_calls(void) { return wrong_thread; }

static void check_audio(test_plugin_t *p) {
	if (p->thread_check && !p->thread_check->is_audio_thread(p->host)) wrong_thread++;
}

static void check_main(test_plugin_t *p) {
	if (p->thread_check && !p->thread_check->is_main_thread(p->host)) wrong_thread++;
}

static const char *features[] = {CLAP_PLUGIN_FEATURE_AUDIO_EFFECT, CLAP_PLUGIN_FEATURE_UTILITY, NULL};

static const clap_plugin_descriptor_t descriptor = {
	.clap_version = CLAP_VERSION_INIT,
	.id = "dev.fire-engine.test.gain",
	.name = "Fire Test Gain",
	.vendor = "Fire Engine",
	.url = "",
	.manual_url = "",
	.support_url = "",
	.version = "1.0.0",
	.description = "Gain, a 32-frame delay, and notes echoed an octave up",
	.features = features,
};

// --- params -------------------------------------------------------------------------------

static uint32_t params_count(const clap_plugin_t *plugin) { return 1; }

static bool params_get_info(const clap_plugin_t *plugin, uint32_t index, clap_param_info_t *info) {
	if (index != 0) return false;
	memset(info, 0, sizeof(*info));
	info->id = GAIN_ID;
	info->flags = CLAP_PARAM_IS_AUTOMATABLE;
	strcpy(info->name, "Gain");
	strcpy(info->module, "Main");
	info->min_value = -60;
	info->max_value = 12;
	info->default_value = 0;
	return true;
}

static bool params_get_value(const clap_plugin_t *plugin, clap_id id, double *out) {
	test_plugin_t *p = plugin->plugin_data;
	check_main(p);
	if (id != GAIN_ID) return false;
	*out = p->gain_db;
	return true;
}

static bool params_value_to_text(const clap_plugin_t *plugin, clap_id id, double value, char *out, uint32_t capacity) {
	if (id != GAIN_ID) return false;
	snprintf(out, capacity, "%.1f dB", value);
	return true;
}

static bool params_text_to_value(const clap_plugin_t *plugin, clap_id id, const char *text, double *out) {
	if (id != GAIN_ID) return false;
	*out = atof(text);
	return true;
}

static void apply_param(test_plugin_t *p, const clap_event_header_t *h) {
	if (h->space_id != CLAP_CORE_EVENT_SPACE_ID || h->type != CLAP_EVENT_PARAM_VALUE) return;
	const clap_event_param_value_t *e = (const clap_event_param_value_t *)h;
	if (e->param_id == GAIN_ID) p->gain_db = e->value;
}

static void params_flush(const clap_plugin_t *plugin, const clap_input_events_t *in, const clap_output_events_t *out) {
	test_plugin_t *p = plugin->plugin_data;
	uint32_t n = in->size(in);
	for (uint32_t i = 0; i < n; i++) apply_param(p, in->get(in, i));
}

static const clap_plugin_params_t params = {params_count, params_get_info, params_get_value, params_value_to_text, params_text_to_value, params_flush};

// --- ports, latency, state ----------------------------------------------------------------

static uint32_t audio_ports_count(const clap_plugin_t *plugin, bool is_input) { return 1; }

static bool audio_ports_get(const clap_plugin_t *plugin, uint32_t index, bool is_input, clap_audio_port_info_t *info) {
	if (index != 0) return false;
	info->id = is_input ? 0 : 1;
	strcpy(info->name, is_input ? "In" : "Out");
	info->flags = CLAP_AUDIO_PORT_IS_MAIN;
	info->channel_count = 2;
	info->port_type = CLAP_PORT_STEREO;
	info->in_place_pair = CLAP_INVALID_ID;
	return true;
}

static const clap_plugin_audio_ports_t audio_ports = {audio_ports_count, audio_ports_get};

static uint32_t note_ports_count(const clap_plugin_t *plugin, bool is_input) { return 1; }

static bool note_ports_get(const clap_plugin_t *plugin, uint32_t index, bool is_input, clap_note_port_info_t *info) {
	if (index != 0) return false;
	info->id = is_input ? 2 : 3;
	info->supported_dialects = CLAP_NOTE_DIALECT_CLAP | CLAP_NOTE_DIALECT_MIDI;
	info->preferred_dialect = CLAP_NOTE_DIALECT_CLAP;
	strcpy(info->name, is_input ? "Notes in" : "Notes out");
	return true;
}

static const clap_plugin_note_ports_t note_ports = {note_ports_count, note_ports_get};

static uint32_t latency_get(const clap_plugin_t *plugin) { return DELAY; }

static const clap_plugin_latency_t latency = {latency_get};

static bool state_save(const clap_plugin_t *plugin, const clap_ostream_t *stream) {
	test_plugin_t *p = plugin->plugin_data;
	check_main(p);
	return stream->write(stream, &p->gain_db, sizeof(double)) == sizeof(double);
}

static bool state_load(const clap_plugin_t *plugin, const clap_istream_t *stream) {
	test_plugin_t *p = plugin->plugin_data;
	check_main(p);
	double v;
	if (stream->read(stream, &v, sizeof(double)) != sizeof(double)) return false;
	p->gain_db = v;
	return true;
}

static const clap_plugin_state_t state = {state_save, state_load};

// --- the plug-in --------------------------------------------------------------------------

static bool plugin_init(const clap_plugin_t *plugin) {
	test_plugin_t *p = plugin->plugin_data;
	p->thread_check = p->host->get_extension(p->host, CLAP_EXT_THREAD_CHECK);
	check_main(p);
	return true;
}

static void plugin_destroy(const clap_plugin_t *plugin) {
	test_plugin_t *p = plugin->plugin_data;
	check_main(p);
	free(p);
}

static bool plugin_activate(const clap_plugin_t *plugin, double sample_rate, uint32_t min_frames, uint32_t max_frames) {
	test_plugin_t *p = plugin->plugin_data;
	check_main(p);
	memset(p->ring, 0, sizeof(p->ring));
	p->pos = 0;
	p->active = 1;
	return max_frames <= MAX_FRAMES;
}

static void plugin_deactivate(const clap_plugin_t *plugin) {
	test_plugin_t *p = plugin->plugin_data;
	check_main(p);
	p->active = 0;
}

static bool plugin_start_processing(const clap_plugin_t *plugin) {
	test_plugin_t *p = plugin->plugin_data;
	check_audio(p);
	p->processing = 1;
	return true;
}

static void plugin_stop_processing(const clap_plugin_t *plugin) {
	test_plugin_t *p = plugin->plugin_data;
	p->processing = 0;
}

static void plugin_reset(const clap_plugin_t *plugin) {
	test_plugin_t *p = plugin->plugin_data;
	memset(p->ring, 0, sizeof(p->ring));
}

static clap_process_status plugin_process(const clap_plugin_t *plugin, const clap_process_t *process) {
	test_plugin_t *p = plugin->plugin_data;
	check_audio(p);
	if (!p->processing) wrong_thread++; // process before start_processing
	const uint32_t n = process->frames_count;
	const uint32_t events = process->in_events->size(process->in_events);
	uint32_t next = 0;
	for (uint32_t i = 0; i < n; i++) {
		// Events at this frame first: sample-accurate gain, echoed notes.
		while (next < events) {
			const clap_event_header_t *h = process->in_events->get(process->in_events, next);
			if (h->time > i) break;
			apply_param(p, h);
			if (h->space_id == CLAP_CORE_EVENT_SPACE_ID && (h->type == CLAP_EVENT_NOTE_ON || h->type == CLAP_EVENT_NOTE_OFF)) {
				clap_event_note_t echo = *(const clap_event_note_t *)h;
				echo.key = echo.key + 12;
				process->out_events->try_push(process->out_events, &echo.header);
			}
			next++;
		}
		const float g = (float)pow(10.0, p->gain_db / 20.0);
		for (int c = 0; c < 2; c++) {
			float x = process->audio_inputs[0].data32[c][i];
			process->audio_outputs[0].data32[c][i] = p->ring[c][p->pos] * g;
			p->ring[c][p->pos] = x;
		}
		p->pos = (p->pos + 1) % DELAY;
	}
	while (next < events) apply_param(p, process->in_events->get(process->in_events, next++));
	return CLAP_PROCESS_CONTINUE;
}

static const void *plugin_get_extension(const clap_plugin_t *plugin, const char *id) {
	if (!strcmp(id, CLAP_EXT_PARAMS)) return &params;
	if (!strcmp(id, CLAP_EXT_AUDIO_PORTS)) return &audio_ports;
	if (!strcmp(id, CLAP_EXT_NOTE_PORTS)) return &note_ports;
	if (!strcmp(id, CLAP_EXT_LATENCY)) return &latency;
	if (!strcmp(id, CLAP_EXT_STATE)) return &state;
	return NULL;
}

static void plugin_on_main_thread(const clap_plugin_t *plugin) {}

// --- factory and entry --------------------------------------------------------------------

static uint32_t factory_count(const clap_plugin_factory_t *factory) { return 1; }

static const clap_plugin_descriptor_t *factory_descriptor(const clap_plugin_factory_t *factory, uint32_t index) {
	return index == 0 ? &descriptor : NULL;
}

static const clap_plugin_t *factory_create(const clap_plugin_factory_t *factory, const clap_host_t *host, const char *id) {
	if (!clap_version_is_compatible(host->clap_version) || strcmp(id, descriptor.id)) return NULL;
	test_plugin_t *p = calloc(1, sizeof(test_plugin_t));
	p->host = host;
	p->plugin = (clap_plugin_t){
		.desc = &descriptor,
		.plugin_data = p,
		.init = plugin_init,
		.destroy = plugin_destroy,
		.activate = plugin_activate,
		.deactivate = plugin_deactivate,
		.start_processing = plugin_start_processing,
		.stop_processing = plugin_stop_processing,
		.reset = plugin_reset,
		.process = plugin_process,
		.get_extension = plugin_get_extension,
		.on_main_thread = plugin_on_main_thread,
	};
	return &p->plugin;
}

static const clap_plugin_factory_t factory = {factory_count, factory_descriptor, factory_create};

static bool entry_init(const char *path) { return true; }
static void entry_deinit(void) {}
static const void *entry_get_factory(const char *id) { return strcmp(id, CLAP_PLUGIN_FACTORY_ID) ? NULL : &factory; }

EXPORT const clap_plugin_entry_t clap_entry = {CLAP_VERSION_INIT, entry_init, entry_deinit, entry_get_factory};

// --- layouts ------------------------------------------------------------------------------

// The size of each struct, then the offset of each field, as the C
// compiler lays them out: the Odin bindings must agree.
#define S(T) {#T, -1, sizeof(T)}
#define F(T, f) {#T "." #f, 0, offsetof(T, f)}

typedef struct {
	const char *name;
	int is_offset;
	size_t value;
} layout_t;

static const layout_t layouts[] = {
	S(clap_version_t), S(clap_plugin_entry_t), S(clap_plugin_factory_t), S(clap_plugin_descriptor_t),
	F(clap_plugin_descriptor_t, features), S(clap_host_t), F(clap_host_t, get_extension), F(clap_host_t, request_callback),
	S(clap_plugin_t), F(clap_plugin_t, process), F(clap_plugin_t, on_main_thread), S(clap_process_t),
	F(clap_process_t, transport), F(clap_process_t, audio_outputs_count), F(clap_process_t, out_events),
	S(clap_audio_buffer_t), F(clap_audio_buffer_t, constant_mask), S(clap_event_header_t),
	S(clap_event_note_t), F(clap_event_note_t, key), F(clap_event_note_t, velocity),
	S(clap_event_note_expression_t), F(clap_event_note_expression_t, value),
	S(clap_event_param_value_t), F(clap_event_param_value_t, cookie), F(clap_event_param_value_t, value),
	S(clap_event_param_mod_t), S(clap_event_param_gesture_t), S(clap_event_transport_t),
	F(clap_event_transport_t, tempo_inc), F(clap_event_transport_t, bar_number), F(clap_event_transport_t, tsig_denom),
	S(clap_event_midi_t), F(clap_event_midi_t, data), S(clap_event_midi_sysex_t), S(clap_event_midi2_t),
	S(clap_input_events_t), S(clap_output_events_t), S(clap_istream_t), S(clap_ostream_t),
	S(clap_param_info_t), F(clap_param_info_t, cookie), F(clap_param_info_t, module), F(clap_param_info_t, default_value),
	S(clap_plugin_params_t), S(clap_host_params_t), S(clap_audio_port_info_t), F(clap_audio_port_info_t, port_type),
	F(clap_audio_port_info_t, in_place_pair), S(clap_plugin_audio_ports_t), S(clap_note_port_info_t),
	S(clap_plugin_note_ports_t), S(clap_plugin_latency_t), S(clap_plugin_tail_t), S(clap_plugin_state_t),
	S(clap_window_t), S(clap_gui_resize_hints_t), F(clap_gui_resize_hints_t, aspect_ratio_width), S(clap_plugin_gui_t),
	F(clap_plugin_gui_t, hide), S(clap_host_gui_t), S(clap_host_thread_check_t), S(clap_host_log_t),
};

EXPORT int fire_clap_layout(int index, const char **name, int *is_offset, uint64_t *value) {
	if (index < 0 || index >= (int)(sizeof(layouts) / sizeof(layouts[0]))) return 0;
	*name = layouts[index].name;
	*is_offset = layouts[index].is_offset == 0;
	*value = layouts[index].value;
	return 1;
}
