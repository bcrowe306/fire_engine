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
