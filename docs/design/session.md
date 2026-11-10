---
title: Session format design
description: How fire:session stores a session as versioned chunks, stays compatible across engine versions, and loads into a running engine without a glitch.
---

`fire:session` saves the clock and the graph as one tree of chunks. This
page records the format and the choices behind it; the
[sessions guide](/guides/sessions/) shows how to use it.

## Chunks

Every saved thing is a **chunk**: a 16-byte header and a payload.

| Bytes | Field |
|-------|-------|
| 0–3 | tag: four ASCII bytes |
| 4–7 | version: u32, little-endian |
| 8–15 | payload size: u64, little-endian |

A payload holds values, child chunks, or a fixed run of values followed by
child chunks. Values are little-endian with no type tags: `u8`, `bool` (one
byte), `u32`, `i64`/`int`, `f64`, `f32`, and byte strings and sample arrays
(a u64 count, then the data). The reader of a chunk reads values in the
order its version says they were written.

Compatibility follows from three rules:

1. **Unknown chunks are skipped.** Readers look for the child tags they
   know and pass over the rest by size.
2. **Values are only ever appended.** A newer writer adds values at the end
   of a chunk without children, or adds child chunks, and bumps the
   version. An older reader stops reading early; the newer reader checks
   the version before reading the new values.
3. **Every read is bounded.** Reading past a payload sets the reader's
   error (`.Invalid_Data`) and returns zeros from then on; counts are
   checked against the bytes left before anything is allocated. A
   truncated or random file is reported, never read out of bounds (the
   tests feed thousands of random buffers through the graph loader).

A major break would bump `session.FORMAT_VERSION` past what older engines
accept; they then refuse the file (`.Unsupported`) instead of
misreading it.

Binary rather than JSON: plug-in states and impulse responses are bytes
and samples, which would be base64 in JSON, and large clips save and load
at hundreds of MB/s. `tools/session_dump` prints a file when you need to
look inside.

## Layout

```
FSES v1                  session
  CLCK v1                clock: tempo, meter, override, leader, timelines (each with rate,
                         position, loop and an optional tempo map)
  GRPH v1                graph: input and output channel counts, then
    NODE v1              index, type ID, in and out channels, then
      PARM v1            parameter id/value pairs (only those that were set)
      DATA vN            the node's own state; N = its type's state_version
    ...
    CONN v1              connections in order: source, destination, channels (-1 for events)
  ....                   the app's chunks, any tags of its own
```

Node and clip payloads use their own tags inside `DATA`: `MCLP` (MIDI
clip), `ACLP` (audio clip), `UCLP` (automation clip), `SMAP` (sample map),
and a nested graph's `GRPH`.

Connections are saved in the order they were made, because inputs with
several sources are summed in that order: the same order gives the same
floating-point sums, so a loaded graph renders bit for bit like the one
that was saved (the round-trip tests compare exactly).

## Node types and the registry

A node's vtable names its type (`type_id`, stable forever once shipped)
and the version of what its `save` writes. Loading needs the reverse
mapping, from a name to code that makes the node, so a
`core.Node_Registry` maps type IDs to loaders. Each package registers its
own types, with whatever its loaders need from the app (a streamer for
audio files, a disk writer for recorders); `session.register_builtin`
registers them all.

A loader receives the node's `DATA` payload and returns an unprepared node,
as the type's `*_create` would. Constructor arguments (an EQ's band count,
a convolution's impulse response) go in `DATA`; parameter values don't,
because the graph saves those for every node alike.

### Placeholders

A node whose type is not registered, or whose loader fails, is replaced by
a silent placeholder that keeps the type ID, the `DATA` payload and the
parameter values, and writes them back as they were when saved. So a
session survives being opened where a plug-in is missing, and saving it
there does not lose the plug-in's state. The connections of a placeholder
are kept like any other.

## Parameter values

The graph remembers, on the control thread, the last value each parameter
was set to (`set_param`, `set_param_ramp`), and saves exactly those.
Parameters never set are not saved, so a node made with a constructor
argument that a parameter also reflects (a filter made in highpass mode)
keeps it, and a later engine's new default applies to parameters the user
never touched. The alternative, asking nodes for their current values,
would need a new realtime-safe query on every node and would save values
that automation is moving instead of the user's settings.

A loaded node must start exactly at its saved values, not glide to them
from its defaults (a 20 ms fade at the start of a render would make a
loaded session sound different). Values can't go through the parameter
queue, which has a fixed size and drains only while audio runs, so a large
session loaded before audio starts would overflow it. Instead each loaded
node carries its starting values in its slot. The audio thread hands them
to the node as zero-length ramps (jumps) before anything else in its first
blocks, at most `max_pending_params` per block; the rest follow in the next
blocks. The cost on the audio thread is one comparison per node per block.

## Loading into a running engine

`session.load` replaces the session's contents, and may run while audio
plays:

1. The clock's saved timelines are added beside the current ones.
2. The saved nodes are added to the graph, without committing, with
   timeline IDs remapped to the new timelines.
3. If anything failed, what was added is removed (the old nodes were
   never touched, and nothing was committed), and the session is as it was.
4. Otherwise the old nodes are removed and the graph is committed once: the
   audio thread switches from the old plan to the new one between two
   blocks. Then the old timelines are removed.

The graph's usual rules for edits make this safe: nodes are prepared on
the control thread, the audio thread only ever sees complete plans, and
removed nodes are freed after the audio thread has retired the plans
using them. The tests load a session into a graph while rendering, with
allocation trapped on the audio thread.

Timelines load stopped, at their saved positions: a session that starts
playing by itself on opening would surprise users. Apps that want
otherwise can store a play flag in their own chunk.

## Files

Audio files (clips, sample zones), recorders' directories and plug-in
libraries are stored by path twice: absolute, and relative to the session
file's directory. On loading, the relative path is tried first, so a
session folder copied to another machine with its audio still finds its
files; the absolute path covers files kept elsewhere, like a sample
library.

`session.save` writes `<path>.tmp` and renames it over `<path>`, so an
existing session is replaced only by a complete new one.

## Performance

Measured on an Apple M-series laptop at `-o:speed`, for a session of
1,408 nodes: 128 synth tracks, each with a 4,000-note MIDI clip, a 16-band
EQ with all 80 band parameters set, and four automated gains: 18.5 MB,
saved in 18 ms (about 1 GB/s) and loaded in 29 ms (about 630 MB/s),
clips rebuilt and nodes prepared. Most of the size is the notes, at 34
bytes each.
