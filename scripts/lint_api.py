#!/usr/bin/env python3
"""Pads is a client of its API (docs/design/api.md): once a module is built,
the UI and the test-script commands (package `pads`, apps/pads/*.odin) do
what it does through `pads_api`, not by calling the model. This fails on a
call into the model that a built module's API owns.

    python3 scripts/lint_api.py

A line may say why it is an exception with `// api-lint: <reason>`.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UI = os.path.join(ROOT, "apps", "pads")

# Module: what only its API may do (regexes over a line of the UI's code).
MODULES = {
    "history": [
        (r"\bapp\.(undo|redo)\(", "history_undo / history_redo"),
        (r"\bapp\.(undo_name|redo_name)\(", "history_undo_name / history_redo_name"),
        (r"\.history\.(undo|redo)\b", "history_state / history_step_name"),
    ],
    "transport": [
        (r"\bpm\.(play|stop|silence_all|set_bpm|tap|tap_start_due)\(", "transport_play / stop / silence / set_tempo / tap"),
        (r"\bpm\.set_transport\([^)]*\.(Loop|Count_In|Metro_\w+|Time_Sig)\b", "transport_set_*"),
        (r"\b(project|p)\.song_mode\s*=[^=]", "transport_set_song_mode"),
        (r"\b(engine|e)\.metronome\s*=[^=]", "transport_set_metronome"),
    ],
    "project": [
        (r"\bpm\.model_(new|new_from|load|save|save_as|save_copy|move|load_backup|discard_backup|save_backup)\(", "project_new / open / save / save_as / rename / recover"),
    ],
    "pads": [
        (r"\bpm\.set_pad\([^)]*\.(Name|Color|Mode|Volume|Pan|Mute|Solo|Choke|Monitor)\b", "pad_set_name / color / mode / volume / pan / mute / solo / choke / monitor"),
        (r"\bpm\.(set_pad_kind|clear_pad|duplicate_pad|make_synth|make_slicer|make_sampler|empty_slicer|load_onto_pad|arm_track)\(", "pad_set_kind / clear / duplicate / load_sample / set_armed"),
    ],
    "effects": [
        (r"\bpm\.(set_target_slot|set_insert|swap_slots|hold_perf_fx|set_perf_intensity|set_send_pre)\(", "effect_set / set_plugin / clear / set_on / swap / hold / set_intensity / set_send_pre"),
    ],
    "devices": [
        (r"\bpm\.(preset_apply|preset_apply_builtin|preset_save|make_plugin_pad)\(", "device_load_preset / load_preset_file / save_preset / load_plugin"),
    ],
    "mixer": [
        (r"\bpm\.(add_bus|delete_bus|rename_bus|set_bus_dest|set_pad_bus|group_pads|ungroup|set_group_folded|set_pad_cue|set_bus_cue|main_loudness_reset|set_bus)\(", "mixer_* (buses, outputs, groups, cue, loudness)"),
    ],
    "sequencer": [
        (r"\bpm\.(select_slot|rename_sequence|set_sequence_tempo|set_sequence_color|duplicate_sequence|double_sequence|clear_sequence|copy_sequence|set_bars|set_swing|quantize_sequence|set_track_loop|set_midi_fx)\(", "sequence_*"),
        (r"\bpm\.set_transport\([^)]*\.Quantize", "sequence_set_input_quantize"),
        # (The note editor's drags, its velocity and chance lanes and its CC
        # and automation drawing stay its own until the ui module: they are
        # gestures inside the grid.)
        (r"\bpm\.(add_note|remove_notes|set_note|add_point|set_point|remove_point|add_cc|set_cc)\(", "sequence_add_note / set_note / remove_notes / add_point / remove_point / add_cc", None, ("ui_sequence.odin",)),
    ],
    "audio": [
        (r"\bpm\.(split_at|delete_range|crop_to|delete_region|normalize_region|use_take|consolidate|set_part_warp|clear_clip|add_take_file)\(", "audio_*"),
        # (The Audio tab's region drags (move, trim, fade, its gain and pan)
        # stay its own until the ui module: gestures with their own base.)
        (r"\bpm\.(move_region|trim_region|set_region)\(", "audio_move_region / trim_region / set_region", None, ("ui_audio.odin",)),
    ],
    "recording": [
        (r"\bpm\.(capture_arm|record_start|record_stop)\(", "recording_record / sample_start / sample_stop"),
    ],
    # (The Settings window is the editor of the same fields the registry
    # points at; the test-script commands set them through the API.)
    "settings": [
        (r"\ba\.settings\.(?!theme\b|open\b|page\b)\w+(\.\w+)*\s*=[^=]", "settings_set_number / settings_set_text", "shell.odin"),
    ],
}


def main():
    problems = []
    for f in sorted(os.listdir(UI)):
        if not f.endswith(".odin"):
            continue
        path = os.path.join(UI, f)
        with open(path, encoding="utf-8") as fh:
            for n, line in enumerate(fh, 1):
                code = line.split("//", 1)[0] if "api-lint:" not in line else ""
                for module, rules in MODULES.items():
                    for rule in rules:
                        pattern, use = rule[0], rule[1]
                        if len(rule) > 2 and rule[2] is not None and f != rule[2]:
                            continue
                        if len(rule) > 3 and f in rule[3]:
                            continue
                        if re.search(pattern, code):
                            problems.append(f"apps/pads/{f}:{n}: the {module} module's API does this: use {use}\n\t{line.strip()}")
    if problems:
        print("\n".join(problems), file=sys.stderr)
        print(f"lint_api: {len(problems)} call(s) past the API", file=sys.stderr)
        sys.exit(1)
    print(f"lint_api: the UI uses the API for {', '.join(MODULES)}")


if __name__ == "__main__":
    main()
