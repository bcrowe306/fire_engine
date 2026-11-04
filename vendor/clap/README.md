# CLAP headers

The C headers of CLAP (CLever Audio Plug-in), version 1.2.10, from
https://github.com/free-audio/clap (tag `1.2.10`,
commit 195b42a004144fab0b3cf95e9c067187d15365b7). MIT licence: see LICENSE.

Only `include/` is copied, unchanged. Fire Engine's CLAP support doesn't
compile them (its bindings in `f_engine/sys/clap` are written in Odin);
they build the C test plug-in in `tests/clap`, which checks those bindings
against the real ABI.
