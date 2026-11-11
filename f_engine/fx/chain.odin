package fx

import "fire:core"

// The nine effects in a row: each on or off, in an order of the caller's
// choosing. An effect switched on starts from silence (its lines
// cleared), so an old tail never comes back.
//
//	c: fx.Chain
//	fx.chain_make(&c, 48_000)
//	p := fx.CHAIN_DEFAULTS
//	p.on = {.Reverb}
//	fx.chain_render(&c, &p, left, right, 48_000) // [rt]

// The effects a chain has.
Effect :: enum u8 {Chorus, Compressor, Delay, Distortion, Eq, Filter, Flanger, Phaser, Reverb}

// The order a chain starts in.
CHAIN_ORDER :: [len(Effect)]Effect{.Chorus, .Compressor, .Delay, .Distortion, .Eq, .Filter, .Flanger, .Phaser, .Reverb}

// A chain's settings: the order, which are on, and each one's own.
Chain_Params :: struct {
	order:      [len(Effect)]Effect,
	on:         bit_set[Effect],
	chorus:     Chorus_Params,
	compressor: Compressor_Params,
	delay:      Delay_Params,
	distortion: Distortion_Params,
	eq:         Eq_Params,
	filter:     Filter_Fx_Params,
	flanger:    Flanger_Params,
	phaser:     Phaser_Params,
	reverb:     Reverb_Params,
}

// Every effect off, each at its defaults, in `CHAIN_ORDER`.
CHAIN_DEFAULTS :: Chain_Params {
	order      = CHAIN_ORDER,
	chorus     = CHORUS_DEFAULTS,
	compressor = COMPRESSOR_DEFAULTS,
	delay      = DELAY_DEFAULTS,
	distortion = DISTORTION_DEFAULTS,
	eq         = EQ_DEFAULTS,
	filter     = {filter = FILTER_DEFAULTS},
	flanger    = FLANGER_DEFAULTS,
	phaser     = PHASER_DEFAULTS,
	reverb     = REVERB_DEFAULTS,
}

// A chain's state: every effect's (made with `chain_make`).
Chain :: struct {
	chorus:     Chorus,
	compressor: Compressor,
	delay:      Delay,
	distortion: Distortion,
	eq:         Eq,
	filter:     Filter_Fx,
	flanger:    Flanger,
	phaser:     Phaser,
	reverb:     Reverb,
	was_on:     bit_set[Effect],
}

// Control thread. Makes the effects' lines for rates up to `max_rate`
// (only those of `only`: an effect without its lines renders nothing).
chain_make :: proc(c: ^Chain, max_rate: f64, allocator := context.allocator, only := ~bit_set[Effect]{}) -> core.Error {
	if .Delay in only do delay_make(&c.delay, max_rate, allocator) or_return
	if .Chorus in only do chorus_make(&c.chorus, max_rate, allocator) or_return
	if .Flanger in only do flanger_make(&c.flanger, max_rate, allocator) or_return
	if .Reverb in only do reverb_make(&c.reverb, max_rate, allocator) or_return
	return .None
}

// Control thread. Frees a chain's lines.
chain_destroy :: proc(c: ^Chain, allocator := context.allocator) {
	delay_destroy(&c.delay, allocator)
	chorus_destroy(&c.chorus, allocator)
	flanger_destroy(&c.flanger, allocator)
	reverb_destroy(&c.reverb, allocator)
	c.was_on = {}
}

// Whether `order` holds each effect once.
chain_order_valid :: proc "contextless" (order: [len(Effect)]Effect) -> bool {
	seen: bit_set[Effect]
	for e in order {
		if e > max(Effect) || e in seen do return false
		seen += {e}
	}
	return true
}

// [rt] Silences effect `e` (its lines cleared, its state as new).
chain_reset :: proc "contextless" (c: ^Chain, e: Effect) {
	switch e {
	case .Chorus:
		for &d in c.chorus.delays do delay_clear(&d)
		c.chorus.phase, c.chorus.tick, c.chorus.set = 0, 0, false
	case .Compressor: c.compressor = {}
	case .Delay:      delay_clear(&c.delay)
	case .Distortion: c.distortion = {}
	case .Eq:         c.eq = {}
	case .Filter:     c.filter = {}
	case .Flanger:
		delay_clear(&c.flanger.delay)
		c.flanger.phase, c.flanger.tick = 0, 0
	case .Phaser:     c.phaser = {}
	case .Reverb:     reverb_clear(&c.reverb)
	}
}

// [rt] Runs the effects that are on over `l` and `r` in place, in order.
chain_render :: proc "contextless" (c: ^Chain, p: ^Chain_Params, l, r: []f32, sample_rate: f64) {
	for e in p.on - c.was_on do chain_reset(c, e)
	c.was_on = p.on
	if p.on == {} do return
	order := p.order if chain_order_valid(p.order) else CHAIN_ORDER
	for e in order {
		if e not_in p.on do continue
		switch e {
		case .Chorus:     chorus_render(&c.chorus, &p.chorus, l, r, sample_rate)
		case .Compressor: compressor_render(&c.compressor, &p.compressor, l, r, sample_rate)
		case .Delay:      delay_render(&c.delay, &p.delay, l, r, sample_rate)
		case .Distortion: distortion_render(&c.distortion, &p.distortion, l, r, sample_rate)
		case .Eq:         eq_render(&c.eq, &p.eq, l, r, sample_rate)
		case .Filter:     filter_fx_render(&c.filter, &p.filter, l, r, sample_rate)
		case .Flanger:    flanger_render(&c.flanger, &p.flanger, l, r, sample_rate)
		case .Phaser:     phaser_render(&c.phaser, &p.phaser, l, r, sample_rate)
		case .Reverb:     reverb_render(&c.reverb, &p.reverb, l, r, sample_rate)
		}
	}
}

// [rt] Clears a delay's lines and state (its lines kept).
@(private)
delay_clear :: proc "contextless" (d: ^Delay) {
	lines := d.lines
	for &l in lines do line_clear(&l)
	d^ = {lines = lines}
}

// [rt] Clears a reverb's lines and state (its lines kept).
@(private)
reverb_clear :: proc "contextless" (rv: ^Reverb) {
	keep := rv^
	for &l in keep.feedback do line_clear(&l)
	for &l in keep.allpass do line_clear(&l)
	line_clear(&keep.pre)
	line_clear(&keep.pre_r)
	rv^ = {feedback = keep.feedback, allpass = keep.allpass, pre = keep.pre, pre_r = keep.pre_r, scale = keep.scale}
}
