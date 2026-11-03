// A C interface to Signalsmith Stretch (vendor/signalsmith), for fire:stretch.
// Part of Fire Engine (MIT). Built by scripts/stretch.sh.
#include "signalsmith-stretch.h"

#include <new>
#include <vector>

namespace {
using Stretch = signalsmith::stretch::SignalsmithStretch<float>;

struct Pointers {
	const float *const *data;
	const float *operator[](int c) const { return data[c]; }
};
struct Mut_Pointers {
	float *const *data;
	float *operator[](int c) const { return data[c]; }
};
}

struct fss {
	Stretch stretch;
	int channels;
	fss(long seed) : stretch(seed), channels(0) {}
};

extern "C" {

// Control thread. Configures the default preset for `channels` at
// `sample_rate`, then runs every operation once on silence, at rates up to
// `max_rate`, so the library has sized all its buffers: afterwards reset,
// output_seek and process don't allocate. A fixed seed keeps output
// repeatable. Returns null on failure.
fss *fss_create(int channels, float sample_rate, float max_rate) {
	fss *s = new (std::nothrow) fss(0x5eed);
	if (!s) return nullptr;
	try {
		s->channels = channels;
		s->stretch.presetDefault(channels, sample_rate);
		int seek = s->stretch.outputSeekLength(max_rate) + 1;
		int block = s->stretch.blockSamples() + s->stretch.intervalSamples();
		int n = (seek > block ? seek : block) * 2;
		std::vector<std::vector<float>> in(channels, std::vector<float>(n)), out(channels, std::vector<float>(n));
		std::vector<const float *> ip(channels);
		std::vector<float *> op(channels);
		for (int c = 0; c < channels; ++c) {
			ip[c] = in[c].data();
			op[c] = out[c].data();
		}
		s->stretch.outputSeek(Pointers{ip.data()}, seek);
		s->stretch.process(Pointers{ip.data()}, n, Mut_Pointers{op.data()}, n / 2);
		s->stretch.process(Pointers{ip.data()}, n / 2, Mut_Pointers{op.data()}, n);
		s->stretch.reset();
	} catch (...) {
		delete s;
		return nullptr;
	}
	return s;
}

void fss_destroy(fss *s) { delete s; }

int fss_input_latency(fss *s) { return s->stretch.inputLatency(); }
int fss_output_latency(fss *s) { return s->stretch.outputLatency(); }

// Realtime. Forgets all input and output.
void fss_reset(fss *s) { s->stretch.reset(); }

// Realtime. Starts over so that the next output begins exactly at input[0];
// `frames` should be fss_input_latency + rate × fss_output_latency.
void fss_output_seek(fss *s, const float *const *input, int frames) {
	s->stretch.outputSeek(Pointers{input}, frames);
}

// Realtime. Consumes `in_frames` and produces `out_frames`; their ratio is
// the playback rate.
void fss_process(fss *s, const float *const *input, int in_frames, float *const *output, int out_frames) {
	s->stretch.process(Pointers{input}, in_frames, Mut_Pointers{output}, out_frames);
}

}
