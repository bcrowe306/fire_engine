# Signalsmith Stretch (vendored)

Time-stretching for `fire:stretch`, built by `scripts/stretch.sh` into a
static library with our C wrapper (`f_engine/sys/signalsmith/wrapper.cpp`).

| Library | Version | Source | Licence |
|---------|---------|--------|---------|
| Signalsmith Stretch | tag `1.4.0` (header reports 1.3.2) | https://github.com/Signalsmith-Audio/signalsmith-stretch | MIT, `stretch/LICENSE.txt` |
| Signalsmith Linear | tag `0.6.4` (the version Stretch 1.4.0 pins) | https://github.com/Signalsmith-Audio/linear | MIT, `linear/LICENSE.txt` |

Files are copied unmodified: `signalsmith-stretch.h`, and Linear's headers
(`*.h`, `include/`, `platform/`). To update, copy the new versions over and
update this table. A pure-Odin port is planned; until then these are the
only C++ in Fire Engine.
