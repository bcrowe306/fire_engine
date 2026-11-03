#!/usr/bin/env bash
# Regenerates the read-compatibility fixtures with tools other than ours.
# The signal (see `expected` in audiofile_test.odin), 48 kHz, 1000 frames:
#   channel c, frame i: 0.5 · sin(2π · 441 · (c+1) · i / 48000)
# Needs python3 and macOS afconvert; flac for the FLAC file. The MP3 and Ogg
# files were made on Linux with ffmpeg (see the end of this script).
set -euo pipefail
cd "$(dirname "$0")"

python3 - <<'PY'
import math, struct, wave
for name, ch in (("src_2ch.wav", 2), ("src_4ch.wav", 4)):
    with wave.open(name, "wb") as w:
        w.setnchannels(ch); w.setsampwidth(3); w.setframerate(48000)
        out = bytearray()
        for i in range(1000):
            for c in range(ch):
                v = 0.5 * math.sin(2 * math.pi * 441 * (c + 1) * i / 48000)
                q = max(-8388608, min(8388607, round(v * 8388608)))
                out += struct.pack("<i", q)[:3]
        w.writeframes(bytes(out))
PY

afconvert -f WAVE -d UI8    src_2ch.wav wav_u8.wav
afconvert -f WAVE -d LEI16  src_2ch.wav wav_i16.wav
afconvert -f WAVE -d LEI32  src_2ch.wav wav_i32.wav
afconvert -f WAVE -d LEF32  src_2ch.wav wav_f32.wav
afconvert -f WAVE -d LEF64  src_2ch.wav wav_f64.wav
afconvert -f WAVE -d LEI24  src_4ch.wav wav_i24_4ch.wav   # WAVE_FORMAT_EXTENSIBLE
afconvert -f AIFF -d BEI16  src_2ch.wav aiff_i16.aiff
afconvert -f AIFF -d BEI24  src_2ch.wav aiff_i24.aiff
afconvert -f AIFF -d I8     src_2ch.wav aiff_i8.aiff
afconvert -f AIFC -d BEF32  src_2ch.wav aifc_f32.aifc
afconvert -f AIFC -d BEF64  src_2ch.wav aifc_f64.aifc
mv src_2ch.wav wav_i24.wav
rm src_4ch.wav
flac -s -f -o flac_i24.flac wav_i24.wav

# On Linux (ffmpeg with libmp3lame and libvorbis):
#   ffmpeg -i wav_i24.wav -c:a libmp3lame -b:a 192k mp3_192k.mp3
#   ffmpeg -i wav_i24.wav -c:a libvorbis -q:a 6 ogg_q6.ogg
