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

// --- test only: Signalsmith Linear's FFT, as the reference for fire:dsp's ---

#include <chrono>

extern "C" {

// One real FFT of `size` floats into size/2 complex bins (interleaved re, im
// in `out`), packed or half-bin. Allocates; for tests.
void fss_test_real_fft(int size, int half_bin, const float *in, float *out) {
	if (half_bin) {
		signalsmith::linear::RealFFT<float, false, true> fft(size);
		fft.fft(in, reinterpret_cast<std::complex<float> *>(out));
	} else {
		signalsmith::linear::RealFFT<float, false, false> fft(size);
		fft.fft(in, reinterpret_cast<std::complex<float> *>(out));
	}
}

// Seconds per forward + inverse half-bin real FFT of `size`, over `count` runs.
double fss_test_bench_real_fft(int size, int count) {
	signalsmith::linear::RealFFT<float, false, true> fft(size);
	std::vector<float> time(size, 0.25f);
	std::vector<std::complex<float>> freq(size / 2);
	auto start = std::chrono::steady_clock::now();
	for (int i = 0; i < count; ++i) {
		fft.fft(time.data(), freq.data());
		fft.ifft(freq.data(), time.data());
		time[0] = 0.25f; // keep values bounded
	}
	return std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count() / count;
}

}

#include "signalsmith-linear/stft.h"

extern "C" {

// Test only: runs mono `input` through Linear's DynamicSTFT (Kaiser window
// at `interval`, the given spectrum type: 0 packed, 1 half-bin, 2
// unpacked) with hops taken in turn from `hops`, writing `output`. Each
// hop: write and move input, analyse, multiply each bin by a fixed complex
// gain (so the spectrum path is exercised), synthesise, read and move
// output. Allocates.
void fss_test_stft(int block, int interval, int extra, int kind, const int *hops, int hop_count,
		const float *input, int frames, float *output) {
	auto run = [&](auto &stft) {
		stft.configure(1, 1, block, extra);
		stft.setInterval(interval, stft.kaiser);
		stft.reset();
		int at = 0, k = 0;
		while (true) {
			int h = hops[k++ % hop_count];
			if (at + h > frames) break;
			stft.writeInput(0, h, input + at);
			stft.moveInput(h);
			stft.analyse();
			auto *spec = stft.spectrum(0);
			for (size_t b = 0; b < stft.bands(); ++b) {
				float phase = 0.01f*b;
				spec[b] *= std::complex<float>(std::cos(phase), std::sin(phase))/(1 + 0.002f*b);
			}
			stft.synthesise();
			stft.readOutput(0, h, output + at);
			stft.moveOutput(h);
			at += h;
		}
	};
	if (kind == 1) {
		signalsmith::linear::DynamicSTFT<float, false, 1> s;
		run(s);
	} else if (kind == 2) {
		signalsmith::linear::DynamicSTFT<float, false, 2> s;
		run(s);
	} else {
		signalsmith::linear::DynamicSTFT<float, false, 0> s;
		run(s);
	}
}

}

// --- test only: render a reference case (testkit.Stretch_Case) -------------

#include <cmath>

extern "C" {

// Mirrors testkit.Stretch_Case (field for field, same order and types).
struct fss_case {
	const char *name;
	int32_t signal;
	float sample_rate;
	int32_t channels, in_frames, out_frames;
	int32_t cheaper, split;
	float rate, transpose, tonality_limit, formant;
	int32_t formant_compensate;
	float formant_base;
	int32_t freq_map, mode, flush_frames, seek_at_out, seek_to_in;
	int32_t chunks[4];
};

// Renders case `c` from `input` (c->channels × c->in_frames) into `output`
// (c->channels × c->out_frames) through Signalsmith Stretch, seeded as in
// fss_create. Modes: 0 stream, 1 stream + flush, 2 stream with a seek,
// 3 exact. Streaming starts with outputSeek, then processes chunks of
// output (c->chunks, repeated), taking input at `rate` per output frame
// (rounded down, carrying the fraction); input past the end is silence.
// Returns the seconds spent in the library.
double fss_test_render(const fss_case *c, const float *const *input, float *const *output) {
	int ch = c->channels;
	Stretch s(0x5eed);
	if (c->cheaper) {
		s.presetCheaper(ch, c->sample_rate, c->split != 0);
	} else {
		s.presetDefault(ch, c->sample_rate, c->split != 0);
	}
	s.setTransposeFactor(c->transpose, c->tonality_limit);
	if (c->freq_map == 1) {
		s.setFreqMap([](float f) { return f < 0.02f ? f : 0.02f + (f - 0.02f)*1.25f; });
	}
	s.setFormantFactor(c->formant, c->formant_compensate != 0);
	s.setFormantBase(c->formant_base);

	// Input padded with silence, so reads past the end are simple.
	int padded = c->in_frames + int(c->out_frames*c->rate) + s.outputSeekLength(c->rate) + s.seekLength() + 8192;
	std::vector<std::vector<float>> in(ch, std::vector<float>(padded, 0.0f));
	for (int k = 0; k < ch; ++k) std::copy(input[k], input[k] + c->in_frames, in[k].begin());
	std::vector<const float *> ip(ch);
	std::vector<float *> op(ch);
	auto at_in = [&](int frame) { for (int k = 0; k < ch; ++k) ip[k] = in[k].data() + frame; return Pointers{ip.data()}; };
	auto at_out = [&](int frame) { for (int k = 0; k < ch; ++k) op[k] = output[k] + frame; return Mut_Pointers{op.data()}; };

	auto start = std::chrono::steady_clock::now();
	if (c->mode == 3) {
		s.exact(at_in(0), c->in_frames, at_out(0), c->out_frames);
	} else {
		int main_out = c->out_frames - (c->mode == 1 ? c->flush_frames : 0);
		int seek_len = s.outputSeekLength(c->rate);
		s.outputSeek(at_in(0), seek_len);
		int in_pos = seek_len, out_pos = 0, k = 0;
		double in_acc = seek_len;
		bool sought = false;
		int nchunks = 0;
		while (nchunks < 4 && c->chunks[nchunks] > 0) ++nchunks;
		while (out_pos < main_out) {
			if (c->mode == 2 && !sought && out_pos >= c->seek_at_out) {
				int pre = std::min(s.seekLength(), c->seek_to_in);
				s.seek(at_in(c->seek_to_in - pre), pre, c->rate);
				in_pos = c->seek_to_in;
				in_acc = in_pos;
				sought = true;
			}
			int n = c->chunks[k++ % nchunks];
			if (c->mode == 2 && !sought) n = std::min(n, c->seek_at_out - out_pos);
			n = std::min(n, main_out - out_pos);
			in_acc += n*double(c->rate);
			int n_in = int(std::floor(in_acc)) - in_pos;
			s.process(at_in(in_pos), n_in, at_out(out_pos), n);
			in_pos += n_in;
			out_pos += n;
		}
		if (c->mode == 1) s.flush(at_out(main_out), c->flush_frames, c->rate);
	}
	return std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
}

}
