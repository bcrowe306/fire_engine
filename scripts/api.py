#!/usr/bin/env python3
"""Generates the Pads API's C ABI, remote methods and reference from its
Odin declarations (apps/pads/api/*.odin; see docs/design/api.md).

    python3 scripts/api.py           write the generated files
    python3 scripts/api.py --check   fail if they are out of date, if an API proc
                                     has no doc comment or no test naming it, or
                                     (with clang) if the header doesn't compile

Generated:
    apps/pads/api/include/pads_api.h   the C header (MIT)
    apps/pads/api/gen_c.odin           the C shims and the function table
    apps/pads/api/gen_remote.odin      the remote methods (JSON lines over --control)
    docs/reference/pads-api.md         the reference

An API proc is an exported `name :: proc(api: ^Api, ...)` in the package,
one line, returning `Result` or `(T, Result)`. Types it may use: bool, i64,
f64, f32, string, rawptr, the package's `enum i32`s and structs of those,
`Change_Proc`, `Post_Proc` and `Subscription`.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG = os.path.join(ROOT, "apps", "pads", "api")
TESTS = [os.path.join(ROOT, "tests", "pads_api")]
OUT_H = os.path.join(PKG, "include", "pads_api.h")
OUT_C = os.path.join(PKG, "gen_c.odin")
OUT_R = os.path.join(PKG, "gen_remote.odin")
OUT_DOC = os.path.join(ROOT, "docs", "reference", "pads-api.md")

# The host's procs: not in the table (the app calls them).
HOST_ONLY = {"api_init", "api_destroy", "api_frame"}
# Not over the socket: they take a callback or a pointer of this process.
NOT_REMOTE_TYPES = {"Change_Proc", "Post_Proc", "rawptr"}

SCALARS = {
    "bool": "bool",
    "i64": "int64_t",
    "f64": "double",
    "f32": "float",
    "rawptr": "void*",
    "Subscription": "Pads_Subscription",
    "Change_Proc": "Pads_Change_Fn",
    "Post_Proc": "Pads_Post_Fn",
}

MODULE_TITLES = {
    "api": "The handle, results, threading and versions",
    "subscriptions": "Changes",
    "history": "History: undo, redo, groups, gestures",
    "transport": "Transport",
    "project": "Project: new, open, save, templates, clean up",
    "settings": "Settings, by name",
    "pads": "Pads",
    "params": "Parameters, by reference",
    "effects": "Effects: inserts, bus effects, performance effects, sends, sidechains",
    "devices": "Devices: synth presets, plug-in instruments",
    "mixer": "Mixer: buses, outputs, groups, cue, meters, loudness, latency",
    "sequencer": "Sequencer: sequences, notes, CC, automation, quantize, note repeat, the arpeggiator",
    "audio": "Audio tracks: takes, regions, comping, consolidating, warp",
    "recording": "Recording: Rec, sampling into pads",
    "song": "Song: clips, lanes, tempo and meter lanes, markers, the loop, arrangements",
    "launcher": "Launcher: lanes, launching, stopping, Hold, Record to Song",
    "perform": "Perform: play modes, banks, the selected pad, keys",
}


class Decl:
    pass


def read_sources():
    files = sorted(f for f in os.listdir(PKG) if f.endswith(".odin") and not f.startswith("gen_"))
    out = []
    for f in files:
        with open(os.path.join(PKG, f), encoding="utf-8") as fh:
            out.append((f[:-5], fh.read().split("\n")))
    return out


def doc_above(lines, i):
    doc = []
    k = i - 1
    while k >= 0 and lines[k].startswith("//"):
        doc.insert(0, lines[k][2:].strip() if lines[k].startswith("// ") or lines[k] == "//" else lines[k][2:])
        k -= 1
    private = k >= 0 and lines[k].strip().startswith("@(private")
    return doc, private


def split_params(s):
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


def parse_params(s):
    """`api: ^Api, num, den: i64, from_beat: f64 = 0, count_in := false` -> [(name, type, default)]."""
    params, pending = [], []
    for p in split_params(s):
        default = None
        if ":=" in p:
            name, default = [x.strip() for x in p.split(":=", 1)]
            typ = {"false": "bool", "true": "bool"}.get(default)
            if typ is None:
                typ = "f64" if "." in default else "i64"
            params.append((name, typ, default))
            continue
        if ":" not in p:
            pending.append(p)
            continue
        name, rest = [x.strip() for x in p.split(":", 1)]
        if "=" in rest:
            rest, default = [x.strip() for x in rest.split("=", 1)]
        for n in pending:
            params.append((n, rest, None))
        pending = []
        params.append((name, rest, default))
    return params


def parse():
    procs, enums, structs = [], {}, {}
    for module, lines in read_sources():
        for i, line in enumerate(lines):
            m = re.match(r"^(\w+) :: proc\((.*?)\)(?: -> (.+?))? \{$", line)
            if m:
                doc, private = doc_above(lines, i)
                if private or m.group(1) in HOST_ONLY:
                    continue
                d = Decl()
                d.name, d.module, d.doc = m.group(1), module, doc
                d.params = parse_params(m.group(2))
                if not d.params or d.params[0][1] != "^Api":
                    continue
                d.params = d.params[1:]
                for pname, _, _ in d.params:
                    if pname in ("r", "v", "val", "ok", "out", "out_len", "out_cap", "args", "obj"):
                        sys.exit(f"api.py: {d.name}: a parameter may not be named {pname!r} (the generated code uses it)")
                ret = (m.group(3) or "").strip()
                if ret == "Result":
                    d.value = None
                else:
                    rm = re.match(r"^\((\w+), Result\)$", ret)
                    if not rm:
                        sys.exit(f"api.py: {d.name}: returns {ret!r}; an API proc returns Result or (T, Result)")
                    d.value = rm.group(1)
                procs.append(d)
                continue
            m = re.match(r"^(\w+) :: enum i32 \{", line)
            if m:
                doc, private = doc_above(lines, i)
                members = []
                k = i + 1
                while not lines[k].startswith("}"):
                    mm = re.match(r"^\t(\w+),", lines[k])
                    if mm:
                        members.append(mm.group(1))
                    k += 1
                if not private:
                    enums[m.group(1)] = (doc, members)
                continue
            m = re.match(r"^(\w+) :: struct \{", line)
            if m:
                doc, private = doc_above(lines, i)
                if private or m.group(1) in ("Api",) or m.group(1).startswith("Table_"):
                    continue
                fields = []
                k = i + 1
                while not lines[k].startswith("}"):
                    fm = re.match(r"^\t([\w, ]+):\s*([\w\[\]]+),\s*(?://\s*(.*))?$", lines[k])
                    if fm:
                        for n in fm.group(1).split(","):
                            fields.append((n.strip(), fm.group(2), fm.group(3) or ""))
                    k += 1
                structs[m.group(1)] = (doc, fields)
    return procs, enums, structs


def c_type(t, enums, structs):
    if t in SCALARS:
        return SCALARS[t]
    if t in enums or t in structs:
        return "Pads_" + t
    sys.exit(f"api.py: type {t!r} isn't one the C ABI carries")


def c_params(d, enums, structs):
    out = ["Pads_Api* api"]
    for name, typ, _ in d.params:
        if typ == "string":
            out += [f"const char* {name}", f"int64_t {name}_len"]
        elif typ == "[]i64":
            out += [f"const int64_t* {name}", f"int64_t {name}_len"]
        else:
            out.append(f"{c_type(typ, enums, structs)} {name}")
    if d.value == "string":
        out += ["char* out", "int64_t out_cap", "int64_t* out_len"]
    elif d.value:
        out.append(f"{c_type(d.value, enums, structs)}* out")
    return out


def c_comment(doc, indent=""):
    if not doc:
        return ""
    return "".join(f"{indent}// {l}".rstrip() + "\n" for l in doc)


def gen_header(procs, enums, structs):
    h = []
    h.append("// The Pads API, for C (generated by scripts/api.py from apps/pads/api: do not edit).\n")
    h.append("// SPDX-License-Identifier: MIT\n//\n")
    h.append("// A surface or script gets the function table (`Pads_Api_V1`) from the host\n")
    h.append("// and calls through it; it links nothing. Every function takes the table's\n")
    h.append("// `api` and returns a `Pads_Result`; values come back through `out`.\n")
    h.append("// Strings in are UTF-8 with a length; strings out are written into the\n")
    h.append("// caller's buffer, NUL-terminated and cut to fit (`out_len`: their whole length).\n")
    h.append("// Call only on the control thread (`post` from others). See docs/guides/api.md.\n")
    h.append("#ifndef PADS_API_H\n#define PADS_API_H\n\n#include <stdbool.h>\n#include <stdint.h>\n\n")
    h.append("#ifdef __cplusplus\nextern \"C\" {\n#endif\n\n")
    h.append("#define PADS_API_NAME \"fire.pads\"\n#define PADS_API_VERSION 1\n\n")
    h.append("typedef struct Pads_Api Pads_Api;\n")
    h.append("typedef int64_t Pads_Subscription;\n\n")
    for name, (doc, members) in enums.items():
        h.append(c_comment(doc))
        h.append("typedef int32_t Pads_%s;\nenum {\n" % name)
        for k, mem in enumerate(members):
            h.append(f"\tPADS_{upper(name)}_{mem.upper()} = {k},\n")
        h.append("};\n\n")
    h.append("// Called on the control thread when `topic` changed (`index`: which; -1 all).\n")
    h.append("typedef void (*Pads_Change_Fn)(Pads_Api* api, Pads_Topic topic, int64_t index, void* user);\n")
    h.append("// A call posted from another thread, run on the control thread.\n")
    h.append("typedef void (*Pads_Post_Fn)(Pads_Api* api, void* user);\n\n")
    for name, (doc, fields) in structs.items():
        h.append(c_comment(doc))
        h.append("typedef struct Pads_%s {\n" % name)
        for fname, ftype, comment in fields:
            h.append(f"\t{c_type(ftype, enums, structs)} {fname};" + (f" // {comment}" if comment else "") + "\n")
        h.append("} Pads_%s;\n\n" % name)
    h.append("// The function table, version 1. It only grows: `size` says how much of it\n")
    h.append("// the host has (check it before calling a function added later).\n")
    h.append("typedef struct Pads_Api_V1 {\n\tint64_t size;\n\tint64_t version;\n\tPads_Api* api;\n")
    for d in procs:
        h.append(c_comment(d.doc, "\t"))
        h.append(f"\tPads_Result (*{d.name})({', '.join(c_params(d, enums, structs))});\n")
    h.append("} Pads_Api_V1;\n\n")
    h.append("#ifdef __cplusplus\n}\n#endif\n\n#endif\n")
    return "".join(h)


def upper(name):
    return re.sub(r"(?<!^)(?=[A-Z])", "_", name).upper().replace("__", "_")


def odin_c_type(t, enums, structs):
    return {"string": None}.get(t, t)


def gen_c(procs, enums, structs):
    o = []
    o.append("// Generated by scripts/api.py from this package's declarations: do not edit.\n")
    o.append("// The C ABI: a shim a proc (`proc \"c\"`, plain types) and the function table.\n")
    o.append("package pads_api\n\nimport \"base:runtime\"\n\n")
    o.append("// The C function table, version 1 (`Pads_Api_V1` in pads_api.h). Fields are internal.\n")
    o.append("Table_V1 :: struct {\n\tsize:    i64,\n\tversion: i64,\n\tapi:     ^Api,\n")
    for d in procs:
        o.append(f"\t{d.name}: {shim_type(d)},\n")
    o.append("}\n\n")
    o.append("// The C function table of `api` (what a surface asking for \"fire.pads\" 1 gets).\n")
    o.append("api_table :: proc(api: ^Api) -> ^Table_V1 {\n\treturn &api.table\n}\n\n")
    o.append("@(private)\ntable_fill :: proc(api: ^Api) {\n\tt := &api.table\n")
    o.append("\tt.size, t.version, t.api = size_of(Table_V1), VERSION, api\n")
    for d in procs:
        o.append(f"\tt.{d.name} = c_{d.name}\n")
    o.append("}\n")
    for d in procs:
        o.append("\n@(private)\n")
        o.append(f"c_{d.name} :: {shim_type(d)} {{\n")
        o.append("\tcontext = runtime.default_context()\n")
        args = []
        for name, typ, _ in d.params:
            if typ == "string":
                o.append(f"\t{name}_s := string(([^]u8)({name})[:max({name}_len, 0)]) if {name} != nil else \"\"\n")
                args.append(f"{name}_s")
            elif typ == "[]i64":
                o.append(f"\t{name}_s := {name}[:max({name}_len, 0)] if {name} != nil else nil\n")
                args.append(f"{name}_s")
            else:
                args.append(name)
        call = f"{d.name}(api{''.join(', ' + a for a in args)})"
        if d.value is None:
            o.append(f"\treturn {call}\n")
        elif d.value == "string":
            o.append(f"\ts, r := {call}\n")
            o.append("\tif out_len != nil do out_len^ = i64(len(s))\n")
            o.append("\tif out != nil && out_cap > 0 {\n\t\tn := copy(([^]u8)(out)[:out_cap - 1], s)\n\t\t([^]u8)(out)[n] = 0\n\t}\n")
            o.append("\treturn r\n")
        else:
            o.append(f"\tv, r := {call}\n\tif out != nil do out^ = v\n\treturn r\n")
        o.append("}\n")
    return "".join(o)


def shim_type(d):
    ps = ["api: ^Api"]
    for name, typ, _ in d.params:
        if typ == "string":
            ps += [f"{name}: cstring", f"{name}_len: i64"]
        elif typ == "[]i64":
            ps += [f"{name}: [^]i64", f"{name}_len: i64"]
        else:
            ps.append(f"{name}: {typ}")
    if d.value == "string":
        ps += ["out: [^]u8", "out_cap: i64", "out_len: ^i64"]
    elif d.value:
        ps.append(f"out: ^{d.value}")
    return f"proc \"c\" ({', '.join(ps)}) -> Result"


def remote_ok(d):
    return all(t not in NOT_REMOTE_TYPES for _, t, _ in d.params) and d.value not in NOT_REMOTE_TYPES


def gen_remote(procs, enums, structs):
    o = []
    o.append("// Generated by scripts/api.py from this package's declarations: do not edit.\n")
    o.append("// The remote methods: a JSON object a line, {\"method\": \"pads_transport_set_tempo\",\n")
    o.append("// \"args\": {\"bpm\": 120}}, answered {\"result\": \"Ok\", \"value\": ..., \"error\": \"...\"}.\n")
    o.append("package pads_api\n\nimport \"core:encoding/json\"\nimport \"core:strings\"\n\n")
    o.append("// Runs one remote call (`line`, a JSON object) and writes its answer (a JSON\n")
    o.append("// object, one line) into `out`. Control thread.\n")
    o.append("remote_call :: proc(api: ^Api, line: string, out: ^strings.Builder) {\n")
    o.append("\t// (Only the request is temporary: what a call makes is the app's, in its own allocator.)\n")
    o.append("\tv, err := json.parse_string(line, allocator = context.temp_allocator)\n")
    o.append("\tobj, is_obj := v.(json.Object)\n")
    o.append("\tif err != nil || !is_obj {\n\t\tremote_answer(out, .Invalid_Argument, nil, \"not a JSON object\")\n\t\treturn\n\t}\n")
    o.append("\tmethod, _ := obj[\"method\"].(json.String)\n")
    o.append("\targs, _ := obj[\"args\"].(json.Object)\n")
    o.append("\tok := true\n")
    o.append("\tswitch method {\n")
    for d in procs:
        if not remote_ok(d):
            continue
        o.append(f"\tcase \"pads_{d.name}\":\n")
        args = []
        for name, typ, default in d.params:
            if typ in enums:
                o.append(f"\t\t{name} := {typ}(remote_enum(args, \"{name}\", {typ}_NAMES[:], &ok))\n")
            elif typ in structs:
                o.append(f"\t\t{name} := remote_struct_{typ}(args, \"{name}\", &ok)\n")
            else:
                fn = {"bool": "remote_bool", "i64": "remote_i64", "f64": "remote_f64", "f32": "remote_f32", "string": "remote_string", "Subscription": "remote_sub", "[]i64": "remote_i64s"}[typ]
                dflt = ""
                if default is not None:
                    dflt = f", {default}"
                    fn += "_or"
                o.append(f"\t\t{name} := {fn}(args, \"{name}\"{dflt}, &ok)\n")
            args.append(name)
        o.append("\t\tif !ok {\n\t\t\tremote_answer(out, .Invalid_Argument, nil, \"missing or wrong arguments\")\n\t\t\treturn\n\t\t}\n")
        call = f"{d.name}(api{''.join(', ' + a for a in args)})"
        if d.value is None:
            o.append(f"\t\tr := {call}\n\t\tremote_answer(out, r, nil, remote_error(api, r))\n")
        else:
            o.append(f"\t\tval, r := {call}\n\t\tremote_answer(out, r, val, remote_error(api, r))\n")
    o.append("\tcase:\n\t\tremote_answer(out, .Not_Found, nil, \"no such method\")\n\t}\n}\n")
    for name, (_, members) in enums.items():
        o.append(f"\n@(private)\n{name}_NAMES := [?]string{{{', '.join(chr(34) + m + chr(34) for m in members)}}}\n")
    # A struct argument: a JSON object of its fields (any left out: zero).
    used = sorted({t for d in procs if remote_ok(d) for _, t, _ in d.params if t in structs})
    for name in used:
        _, fields = structs[name]
        o.append(f"\n@(private)\nremote_struct_{name} :: proc(args: json.Object, name: string, ok: ^bool) -> {name} {{\n")
        o.append("\tobj, is := args[name].(json.Object)\n\tif !is {\n\t\tok^ = false\n\t\treturn {}\n\t}\n")
        o.append(f"\tv: {name}\n")
        for fname, ftype, _ in fields:
            if ftype in enums:
                o.append(f"\tv.{fname} = {ftype}(remote_enum_or(obj, \"{fname}\", {ftype}_NAMES[:], 0, ok))\n")
            else:
                fn = {"bool": "remote_bool_or", "i64": "remote_i64_or", "f64": "remote_f64_or", "f32": "remote_f32_or"}[ftype]
                zero = {"bool": "false"}.get(ftype, "0")
                o.append(f"\tv.{fname} = {fn}(obj, \"{fname}\", {zero}, ok)\n")
        o.append("\treturn v\n}\n")
    o.append("\n// The remote methods' names (pads_...), in the table's order.\n")
    o.append("REMOTE_METHODS := [?]string{\n")
    for d in procs:
        if remote_ok(d):
            o.append(f"\t\"pads_{d.name}\",\n")
    o.append("}\n")
    return "".join(o)


def md_type(t):
    return f"`{t}`"


def gen_doc(procs, enums, structs):
    o = ["---\ntitle: Pads API\ndescription: \"Everything Pads does, as one API: in Odin (pads_api), in C (pads_api.h) and over the control socket.\"\n---\n\n"]
    o.append("<!-- Generated by scripts/api.py from apps/pads/api. Do not edit: run python3 scripts/api.py. -->\n\n")
    o.append("The Pads API (see the [guide](/guides/api/)). Each procedure is in Odin as\n")
    o.append("`pads_api.name`, in C as `pads_name` (through the function table\n")
    o.append("`Pads_Api_V1`), and over the control socket as the method `pads_name`.\n\n")
    seen_mod = []
    for d in procs:
        if d.module not in seen_mod:
            seen_mod.append(d.module)
    for mod in seen_mod:
        o.append(f"## {MODULE_TITLES.get(mod, mod)}\n\n")
        for d in procs:
            if d.module != mod:
                continue
            ps = ", ".join(f"{n}: {t}" + (f" = {df}" if df is not None else "") for n, t, df in d.params)
            ret = f" -> ({d.value}, Result)" if d.value else " -> Result"
            o.append(f"### {d.name}\n\n```odin\n{d.name} :: proc(api: ^Api{', ' if ps else ''}{ps}){ret}\n```\n\n")
            o.append(" ".join(d.doc) + "\n\n")
    o.append("## Types\n\n")
    for name, (doc, members) in enums.items():
        o.append(f"### {name}\n\n{' '.join(doc)}\n\n`{'`, `'.join(members)}`\n\n")
    for name, (doc, fields) in structs.items():
        o.append(f"### {name}\n\n{' '.join(doc)}\n\n| Field | Type | |\n|---|---|---|\n")
        for fname, ftype, comment in fields:
            o.append(f"| `{fname}` | `{ftype}` | {comment} |\n")
        o.append("\n")
    return "".join(o)


def outputs():
    procs, enums, structs = parse()
    return procs, {
        OUT_H: gen_header(procs, enums, structs),
        OUT_C: gen_c(procs, enums, structs),
        OUT_R: gen_remote(procs, enums, structs),
        OUT_DOC: gen_doc(procs, enums, structs),
    }


def tests_text():
    text = ""
    for d in TESTS:
        if os.path.isdir(d):
            for root, _, files in os.walk(d):
                for f in files:
                    if f.endswith((".odin", ".py", ".c")):
                        with open(os.path.join(root, f), encoding="utf-8") as fh:
                            text += fh.read()
    return text


def main():
    check = "--check" in sys.argv[1:]
    procs, files = outputs()
    problems = []
    if check:
        for path, text in files.items():
            old = open(path, encoding="utf-8").read() if os.path.exists(path) else None
            if old != text:
                problems.append(f"{os.path.relpath(path, ROOT)} is out of date: run python3 scripts/api.py")
        tested = tests_text()
        for d in procs:
            if not d.doc:
                problems.append(f"{d.name}: no doc comment")
            if not re.search(r"\b" + re.escape(d.name) + r"\b", tested):
                problems.append(f"{d.name}: no test names it (tests/pads_api)")
        cc = shutil.which("clang") or shutil.which("cc")
        if cc and os.path.exists(OUT_H):
            with tempfile.TemporaryDirectory() as tmp:
                src = os.path.join(tmp, "h.c")
                with open(src, "w") as fh:
                    fh.write('#include "pads_api.h"\nint main(void) { Pads_Api_V1 t = {0}; return (int)t.size; }\n')
                r = subprocess.run([cc, "-std=c99", "-Wall", "-Wextra", "-Werror", "-fsyntax-only", "-I", os.path.dirname(OUT_H), src], capture_output=True, text=True)
                if r.returncode != 0:
                    problems.append("pads_api.h doesn't compile:\n" + r.stderr)
        if problems:
            print("\n".join(problems), file=sys.stderr)
            sys.exit(1)
        print(f"api: {len(procs)} procs, generated files current")
        return
    for path, text in files.items():
        os.makedirs(os.path.dirname(path), exist_ok=True)
        old = open(path, encoding="utf-8").read() if os.path.exists(path) else None
        if old != text:
            with open(path, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(text)
            print("wrote", os.path.relpath(path, ROOT))
    print(f"api: {len(procs)} procs")


if __name__ == "__main__":
    main()
