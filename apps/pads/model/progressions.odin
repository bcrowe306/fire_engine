package pads_model

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import fc "fire:core"

// Chord progressions: roman numerals (a degree of the key and a
// variation), so they follow the project key. A bank built in, grouped by
// style; your own as files in the settings folder (`PROGRESSION_EXT`, as
// synth presets are); the project keeps the one in use.

// The most chords a progression has (what the window's 16 pads show).
PROGRESSION_CHORDS :: 16
// The longest progression name kept.
PROGRESSION_NAME :: 48
// A progression file's extension.
PROGRESSION_EXT :: ".fprog"
// Chunk tag of a progression file.
PROGRESSION_TAG :: fc.Tag{'P', 'R', 'O', 'G'}
// Version of the progression chunk this version writes.
PROGRESSION_VERSION :: 1

// One chord of a progression: a degree of the key (0 its root; past the
// key's notes, octaves up) and a variation.
Prog_Chord :: struct {
	degree:    int,
	variation: Variation,
}

// A progression: its name and chords.
Progression :: struct {
	name:   [PROGRESSION_NAME]u8,
	count:  int,
	chords: [PROGRESSION_CHORDS]Prog_Chord,
}

// A built-in progression: its name, its style, and its chords as numerals
// (`progression_parse`).
Builtin_Progression :: struct {
	name:   string,
	style:  string,
	chords: string,
}

// The styles the built-in bank is grouped by, in order.
PROGRESSION_STYLES := [?]string{"Pop", "Soul", "Jazz", "Blues", "Cinematic", "Dark", "Modal", "Folk", "Gospel", "Lo-fi"}

// The built-in progressions, written for Pads (common harmony, our own
// names). Numerals are the key's degrees: in a minor key "i iv v" and
// "I IV V" are the same chords.
BUILTIN_PROGRESSIONS := [?]Builtin_Progression{
	{"Sunlit Loop", "Pop", "I V vi IV"},
	{"Open Road", "Pop", "I IV vi V"},
	{"Back Porch", "Pop", "vi IV I V"},
	{"Slow Rise", "Pop", "I vi IV V"},
	{"Glass City", "Pop", "IV I V vi"},
	{"Paper Kites", "Pop", "I V IV V"},
	{"Velvet Room", "Soul", "ii7 V7 I7 vi7"},
	{"Late Bus", "Soul", "I7 iii7 vi7 ii7"},
	{"Honey Glow", "Soul", "IV7 iii7 ii7 I7"},
	{"Corner Booth", "Soul", "vi7 ii7 V7 I7"},
	{"Warm Static", "Soul", "Iadd9 vi7 ii7 V7"},
	{"Turnaround", "Jazz", "I7 vi7 ii7 V7"},
	{"Home Again", "Jazz", "ii7 V7 I7 I7"},
	{"Long Walk", "Jazz", "iii7 vi7 ii7 V7"},
	{"Bridge Lights", "Jazz", "I6 vi7 ii7 V7"},
	{"Blue Hour", "Jazz", "I7 IV7 iii7 vi7 ii7 V7 I7 I7"},
	{"Twelve Bars", "Blues", "I I I I IV IV I I V IV I V"},
	{"Early Change", "Blues", "I IV I I IV IV I I V IV I I"},
	{"Eight Bars", "Blues", "I V IV IV I V I V"},
	{"Minor Shuffle", "Blues", "i i iv i v iv i i"},
	{"Wide Horizon", "Cinematic", "I vi iii IV"},
	{"Tall Ships", "Cinematic", "vi V IV V"},
	{"The Approach", "Cinematic", "IV V vi vi"},
	{"Distant Lights", "Cinematic", "Isus2 V/3 vi IV"},
	{"Long Descent", "Cinematic", "I V/3 vi iii/3 IV I/3 ii V"},
	{"Night Walk", "Dark", "i VI III VII"},
	{"Undertow", "Dark", "i iv v i"},
	{"Cold Stone", "Dark", "i VII VI VII"},
	{"Low Smoke", "Dark", "i VI iv v"},
	{"Ritual", "Dark", "i ii i v"},
	{"Drift", "Modal", "i IV i IV"},
	{"Hard Road", "Modal", "I VII IV I"},
	{"Float", "Modal", "I II I II"},
	{"Sharp Edge", "Modal", "i II i VII"},
	{"Hearth", "Folk", "I IV I V"},
	{"Hillside", "Folk", "I ii IV I"},
	{"Sunday Climb", "Gospel", "IV V iii vi ii V I I"},
	{"Amen", "Gospel", "IV I IV I"},
	{"Rain Window", "Lo-fi", "ii7 V7 iii7 vi7"},
	{"Tape Hiss", "Lo-fi", "Iadd9 IVadd9 vi7 V"},
}

// A progression's name.
progression_name :: proc(p: ^Progression) -> string {
	return strings.truncate_to_byte(string(p.name[:]), 0)
}

// Names progression `p` `name` (cut to fit).
progression_set_name :: proc(p: ^Progression, name: string) {
	p.name = {}
	n := min(len(name), PROGRESSION_NAME - 1)
	for n > 0 && n < len(name) && name[n] & 0xC0 == 0x80 do n -= 1 // (not inside a character)
	copy(p.name[:n], name)
}

// The progression numerals `text` spell: degrees I..VII (either case),
// each with a variation's mark (7, sus4, sus2, add9, 6, /3, /5). False if
// any is not one, or there are more than `PROGRESSION_CHORDS`.
progression_parse :: proc(text: string, name: string = "") -> (p: Progression, ok: bool) {
	progression_set_name(&p, name)
	t := text
	for word in strings.fields_iterator(&t) {
		c := parse_numeral(word) or_return
		if p.count >= PROGRESSION_CHORDS do return p, false
		p.chords[p.count] = c
		p.count += 1
	}
	return p, true
}

// One numeral: "ii7", "IVadd9", "V/3".
@(private)
parse_numeral :: proc(word: string) -> (c: Prog_Chord, ok: bool) {
	@(static, rodata) ROMAN := [7]string{"vii", "iii", "vi", "iv", "ii", "v", "i"} // (longest first)
	@(static, rodata) DEGREE := [7]int{6, 2, 5, 3, 1, 4, 0}
	lower := strings.to_lower(word, context.temp_allocator)
	rest := ""
	found := false
	for r, k in ROMAN do if strings.has_prefix(lower, r) {
		c.degree, rest, found = DEGREE[k], lower[len(r):], true
		break
	}
	if !found do return {}, false
	switch rest {
	case "":     c.variation = .Triad
	case "7":    c.variation = .Seventh
	case "sus4": c.variation = .Sus4
	case "sus2": c.variation = .Sus2
	case "add9": c.variation = .Add9
	case "6":    c.variation = .Sixth
	case "/3":   c.variation = .First_Inversion
	case "/5":   c.variation = .Second_Inversion
	case:        return {}, false
	}
	return c, true
}

// Built-in progression `index`, made.
progression_builtin :: proc(index: int) -> Progression {
	b := BUILTIN_PROGRESSIONS[clamp(index, 0, len(BUILTIN_PROGRESSIONS) - 1)]
	p, _ := progression_parse(b.chords, b.name)
	return p
}

// Chord `index` of progression `p` in key `k`, as built.
progression_chord :: proc(k: Keys, p: ^Progression, index: int) -> Chord {
	if index < 0 || index >= p.count do return {}
	c := p.chords[index]
	return chord_build(k, c.degree, c.variation)
}

// Writes progression `p` (its name, its chords).
write_progression :: proc(w: ^fc.State_Writer, p: ^Progression) {
	fc.write_string(w, progression_name(p))
	fc.write_int(w, p.count)
	for c in p.chords[:p.count] {
		fc.write_int(w, c.degree)
		fc.write_u8(w, u8(c.variation))
	}
}

// Reads a progression `write_progression` wrote.
read_progression :: proc(r: ^fc.State_Reader, p: ^Progression) {
	p^ = {}
	progression_set_name(p, fc.read_string(r))
	p.count = clamp(fc.read_int(r), 0, PROGRESSION_CHORDS)
	for &c in p.chords[:p.count] {
		c.degree = clamp(fc.read_int(r), 0, 48)
		c.variation = Variation(min(fc.read_u8(r), u8(max(Variation))))
	}
}

// Saves progression `p` as `name` in folder `dir` (made if it is
// missing): its path (temporary allocator).
progression_save :: proc(p: ^Progression, dir: string, name: string) -> (path: string, err: fc.Error) {
	if strings.trim_space(name) == "" do return "", .Invalid_Argument
	if !os.is_dir(dir) && os.make_directory_all(dir) != nil do return "", .Device_Error
	x := p^
	progression_set_name(&x, name)
	w: fc.State_Writer
	fc.state_writer_init(&w, context.temp_allocator)
	fc.begin_chunk(&w, PROGRESSION_TAG, PROGRESSION_VERSION)
	write_progression(&w, &x)
	fc.end_chunk(&w)
	data := fc.state_writer_bytes(&w) or_return
	path, _ = filepath.join({dir, strings.concatenate({safe_file_name(name), PROGRESSION_EXT}, context.temp_allocator)}, context.temp_allocator)
	if os.write_entire_file(path, data) != nil do return "", .Device_Error
	return path, .None
}

// Reads the progression at `path`.
progression_read :: proc(path: string) -> (p: Progression, err: fc.Error) {
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil do return {}, .Device_Error
	r := fc.state_reader(data)
	c, ok := fc.read_chunk(&r)
	if !ok || c.tag != PROGRESSION_TAG || c.version > PROGRESSION_VERSION do return {}, .Invalid_Data
	cr := fc.chunk_reader(c)
	read_progression(&cr, &p)
	return p, .None
}

// The progressions in folder `dir`: their names, in order (temporary
// allocator).
progression_list :: proc(dir: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	h, err := os.open(dir)
	if err != nil do return nil
	defer os.close(h)
	infos, _ := os.read_dir(h, -1, context.temp_allocator)
	for fi in infos do if strings.has_suffix(fi.name, PROGRESSION_EXT) do append(&out, strings.trim_suffix(fi.name, PROGRESSION_EXT))
	slice.sort(out[:])
	return out[:]
}
