package fx

// ProVerb's modes, each one's character against the first's, from the
// reference's measurements (scripts/proverb_probe/modes.py writes this
// file; don't edit it by hand).
@(private)
Pv_Mode :: struct {
	first:    f32,  // the late tail's first arrival, against the first mode's
	mid:      f32,  // the middle's decay, against the first mode's
	bass:     f32,  // the bass's decay against the middle's, against the first mode's
	high:     f32,  // and the treble's
	mod:      f32,  // how much it modulates
	late_db:  f32,  // the late tail's level
	early_db: f32,  // the early part's level
	wide:     bool, // its early part differs left and right
	slow:     bool, // its density builds slowly
}

@(private)
PV_MODES := [12]Pv_Mode{
	{first = 1.000, mid = 1.000, bass = 1.000, high = 1.000, mod = 1.000, late_db = 0.00, early_db = 0.00, wide = false, slow = true},
	{first = 1.709, mid = 0.856, bass = 0.829, high = 1.142, mod = 2.429, late_db = -0.66, early_db = 0.00, wide = false, slow = true},
	{first = 1.000, mid = 0.848, bass = 0.847, high = 1.310, mod = 5.286, late_db = 0.92, early_db = -12.97, wide = true, slow = true},
	{first = 0.158, mid = 0.986, bass = 0.935, high = 0.999, mod = 2.143, late_db = -1.46, early_db = -0.00, wide = false, slow = false},
	{first = 1.172, mid = 0.983, bass = 1.066, high = 1.055, mod = 4.143, late_db = -0.81, early_db = -25.70, wide = true, slow = true},
	{first = 0.278, mid = 0.989, bass = 1.004, high = 0.999, mod = 2.429, late_db = -0.44, early_db = -13.79, wide = true, slow = true},
	{first = 1.933, mid = 1.003, bass = 1.052, high = 0.995, mod = 2.286, late_db = -0.61, early_db = -13.79, wide = true, slow = true},
	{first = 0.050, mid = 0.993, bass = 1.012, high = 1.202, mod = 1.857, late_db = -0.08, early_db = -13.79, wide = true, slow = true},
	{first = 0.050, mid = 0.993, bass = 1.023, high = 1.041, mod = 3.286, late_db = 0.85, early_db = -13.79, wide = true, slow = true},
	{first = 1.820, mid = 1.014, bass = 0.998, high = 0.997, mod = 1.714, late_db = -0.69, early_db = -13.72, wide = true, slow = true},
	{first = 0.049, mid = 0.989, bass = 1.065, high = 1.143, mod = 0.857, late_db = 1.78, early_db = -12.66, wide = true, slow = true},
	{first = 0.854, mid = 0.993, bass = 1.035, high = 1.190, mod = 2.714, late_db = 0.06, early_db = -14.10, wide = true, slow = true},
}
