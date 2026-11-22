class_name AudioSynth
extends RefCounted
## Pure-GDScript deterministic PCM16 synthesizer (docs/design/audio.md §2).
## Builds layered AudioStreamWAV clips from seeded noise, pitch-swept oscillators, 2-op FM, state-variable resonant
## filters, soft-clip saturation, radio bandpass filtering, and seamless equal-power loop crossfades.
## Strictly deterministic: every random sample comes from a caller-provided or recipe-seeded RandomNumberGenerator
## (never global randf/randi). Cosmetic only (Net LOCAL).

const SR_DEFAULT := 22050
const SR_CRISP := 44100


static func make_rng(seed_val: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val
	return rng


static func buf(dur: float, sr: int = SR_DEFAULT) -> PackedFloat32Array:
	var n := maxi(int(round(dur * float(sr))), 1)
	var out := PackedFloat32Array()
	out.resize(n)
	return out


## Add a pitch-swept oscillator layer: wave in "sine" | "tri" | "saw" | "square" | "sub".
static func add_tone(b: PackedFloat32Array, sr: int, start: float, dur: float, f0: float, f1: float,
		wave: String = "sine", gain: float = 0.5, atk: float = 0.004, rel: float = 0.05, exp_pitch: bool = true) -> void:
	var n := b.size()
	var i0 := maxi(int(start * float(sr)), 0)
	var count := int(dur * float(sr))
	var i1 := mini(i0 + count, n)
	if i1 <= i0 or count <= 0:
		return
	var phase := 0.0
	var inv_sr := 1.0 / float(sr)
	var atk_s := maxf(atk, 0.0005)
	var rel_s := maxf(rel, 0.001)
	var f0_safe := maxf(f0, 1.0)
	var f1_safe := maxf(f1, 1.0)
	var ratio := f1_safe / f0_safe
	for i in range(i0, i1):
		var local := float(i - i0)
		var t := local * inv_sr
		var u := local / float(count)
		var freq := f0_safe * pow(ratio, u) if exp_pitch else lerpf(f0_safe, f1_safe, u)
		phase += freq * inv_sr
		if phase >= 1.0:
			phase -= floor(phase)
		var s := _osc(phase, wave)
		var env := _env(t, dur, atk_s, rel_s)
		b[i] += s * env * gain


## Add a 2-operator FM layer (metallic clanks, alien harmonic telegraphs, chimes, breech rings).
static func add_fm(b: PackedFloat32Array, sr: int, start: float, dur: float, car0: float, car1: float,
		mod_ratio: float, idx0: float, idx1: float, gain: float = 0.45, atk: float = 0.003, rel: float = 0.06,
		exp_pitch: bool = true) -> void:
	var n := b.size()
	var i0 := maxi(int(start * float(sr)), 0)
	var count := int(dur * float(sr))
	var i1 := mini(i0 + count, n)
	if i1 <= i0 or count <= 0:
		return
	var c_ph := 0.0
	var m_ph := 0.0
	var inv_sr := 1.0 / float(sr)
	var atk_s := maxf(atk, 0.0005)
	var rel_s := maxf(rel, 0.001)
	var c0 := maxf(car0, 1.0)
	var c1 := maxf(car1, 1.0)
	var ratio := c1 / c0
	for i in range(i0, i1):
		var local := float(i - i0)
		var t := local * inv_sr
		var u := local / float(count)
		var cf := c0 * pow(ratio, u) if exp_pitch else lerpf(c0, c1, u)
		var mf := cf * mod_ratio
		c_ph += TAU * cf * inv_sr
		m_ph += TAU * mf * inv_sr
		var idx := lerpf(idx0, idx1, u)
		var s := sin(c_ph + idx * sin(m_ph))
		var env := _env(t, dur, atk_s, rel_s)
		b[i] += s * env * gain


## Add state-variable filtered noise ("lp" | "hp" | "bp" | "raw") with time-varying cutoff sweep.
static func add_noise(b: PackedFloat32Array, sr: int, start: float, dur: float, rng: RandomNumberGenerator,
		gain: float = 0.4, atk: float = 0.005, rel: float = 0.06, filter_type: String = "lp",
		f0: float = 1200.0, f1: float = 400.0, q: float = 1.0) -> void:
	var n := b.size()
	var i0 := maxi(int(start * float(sr)), 0)
	var count := int(dur * float(sr))
	var i1 := mini(i0 + count, n)
	if i1 <= i0 or count <= 0:
		return
	var inv_sr := 1.0 / float(sr)
	var atk_s := maxf(atk, 0.0005)
	var rel_s := maxf(rel, 0.001)
	var lp := 0.0
	var bp := 0.0
	var damp := clampf(1.0 / maxf(q, 0.5), 0.08, 2.0)
	var max_f := float(sr) * 0.42
	for i in range(i0, i1):
		var local := float(i - i0)
		var t := local * inv_sr
		var u := local / float(count)
		var white := rng.randf_range(-1.0, 1.0)
		var s := white
		if filter_type != "raw":
			var fc := clampf(lerpf(f0, f1, u), 25.0, max_f)
			var f := minf(2.0 * sin(PI * fc * inv_sr), 0.92)
			var hp := white - lp - damp * bp
			bp += f * hp
			lp += f * bp
			match filter_type:
				"lp": s = lp
				"hp": s = hp
				"bp": s = bp
		var env := _env(t, dur, atk_s, rel_s)
		b[i] += s * env * gain


## Add a crisp mechanical transient click (high-frequency damped impulse).
static func add_click(b: PackedFloat32Array, sr: int, start: float, gain: float = 0.5, freq: float = 2400.0) -> void:
	add_tone(b, sr, start, 0.018, freq, freq * 0.42, "tri", gain, 0.0005, 0.014, true)


## Add a chord of sine/triangle/saw notes at the same envelope.
static func add_chord(b: PackedFloat32Array, sr: int, start: float, dur: float, freqs: Array,
		wave: String = "tri", gain: float = 0.25, atk: float = 0.01, rel: float = 0.1) -> void:
	if freqs.is_empty():
		return
	var each := gain / sqrt(float(freqs.size()))
	for f: Variant in freqs:
		var hz := float(f)
		add_tone(b, sr, start, dur, hz, hz, wave, each, atk, rel, false)


## Soft-clipping waveshaper for industrial punch without harsh digital clipping.
static func saturate(b: PackedFloat32Array, drive: float = 1.6) -> void:
	if drive <= 0.01:
		return
	var norm := 1.0 / tanh(drive)
	for i in b.size():
		b[i] = tanh(b[i] * drive) * norm


## Narrow radio intercom bandpass filter (600..2200 Hz) for restrained deadpan pilot cues.
static func bandpass_radio(b: PackedFloat32Array, sr: int, lo_hz: float = 600.0, hi_hz: float = 2200.0) -> void:
	var inv_sr := 1.0 / float(sr)
	var hp_rc := 1.0 / (TAU * maxf(lo_hz, 40.0))
	var hp_a := hp_rc / (hp_rc + inv_sr)
	var lp_rc := 1.0 / (TAU * clampf(hi_hz, lo_hz + 100.0, float(sr) * 0.45))
	var lp_a := inv_sr / (lp_rc + inv_sr)
	var prev_in := 0.0
	var hp_out := 0.0
	var lp_out := 0.0
	for i in b.size():
		var x := b[i]
		hp_out = hp_a * (hp_out + x - prev_in)
		prev_in = x
		lp_out += lp_a * (hp_out - lp_out)
		b[i] = tanh(lp_out * 1.4) * 0.85


## Equal-power tail-to-head overlap-add for click-free seamless loops. Returns the trimmed loop buffer.
static func make_seamless(b: PackedFloat32Array, sr: int, xfade_sec: float = 0.15) -> PackedFloat32Array:
	var xf := clampi(int(round(xfade_sec * float(sr))), 16, b.size() / 4)
	var out_n := b.size() - xf
	if out_n <= xf:
		return b
	var out := PackedFloat32Array()
	out.resize(out_n)
	for i in out_n:
		out[i] = b[i]
	for i in xf:
		var u := float(i) / float(xf)
		var fade_in := sin(u * PI * 0.5)
		var fade_out := cos(u * PI * 0.5)
		out[i] = b[i] * fade_in + b[out_n + i] * fade_out
	return out


## Normalize buffer peak to `ceiling` (default -0.7 dBFS), remove DC offset, and sanitize any NaN/Inf.
static func normalize(b: PackedFloat32Array, ceiling: float = 0.92) -> void:
	var n := b.size()
	if n == 0:
		return
	var sum := 0.0
	for i in n:
		var v := b[i]
		if is_nan(v) or is_inf(v):
			b[i] = 0.0
			v = 0.0
		sum += v
	var mean := sum / float(n)
	var peak := 0.0
	for i in n:
		var v := b[i] - mean
		b[i] = v
		peak = maxf(peak, absf(v))
	if peak < 1e-6:
		return
	var sc := minf(ceiling / peak, 8.0) if peak > ceiling else ceiling / peak
	for i in n:
		b[i] = clampf(b[i] * sc, -0.98, 0.98)


## Pack float samples (-1..+1) into a 16-bit signed LE mono AudioStreamWAV.
## One-shots receive a subtle 5 ms end taper to guarantee zero tail clicks; loops receive a 4 ms boundary blend so
## sample[-1] meets sample[0] seamlessly without clicks.
static func to_wav(b: PackedFloat32Array, sr: int = SR_DEFAULT, loop: bool = false) -> AudioStreamWAV:
	var n := b.size()
	var work := b.duplicate()
	if loop and n > 32:
		var edge := clampi(int(round(0.004 * float(sr))), 8, n / 8)
		var target := (work[0] + work[n - 1]) * 0.5
		var d0 := target - work[0]
		var d1 := target - work[n - 1]
		for i in edge:
			var u := float(i) / float(edge)
			var w := 0.5 * (1.0 + cos(PI * u))
			work[i] = clampf(work[i] + d0 * w, -0.98, 0.98)
			work[n - 1 - i] = clampf(work[n - 1 - i] + d1 * w, -0.98, 0.98)
	elif not loop and n > 16:
		var tail := clampi(int(round(0.006 * float(sr))), 8, n / 3)
		var start_i := n - tail
		for i in tail:
			var u := float(i + 1) / float(tail)
			work[start_i + i] *= 0.5 * (1.0 + cos(PI * u))
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	for i in n:
		var v := clampf(work[i], -1.0, 1.0)
		var s := clampi(int(round(v * 32767.0)), -32768, 32767)
		if s < 0:
			s += 65536
		bytes[i * 2] = s & 0xFF
		bytes[i * 2 + 1] = (s >> 8) & 0xFF
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = sr
	wav.stereo = false
	wav.data = bytes
	if loop:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = n
	else:
		wav.loop_mode = AudioStreamWAV.LOOP_DISABLED
	return wav


## Compute objective DSP diagnostics for tests and tools:
## {samples, duration, rms, rms_db, peak, mean, first, last, seam_delta, tail_rms, zcr_hz, low_ratio, has_nan, hash}.
static func analyze(wav: AudioStreamWAV) -> Dictionary:
	if wav == null:
		return {
			"samples": 0, "duration": 0.0, "rms": 0.0, "rms_db": -120.0, "peak": 0.0, "mean": 0.0,
			"first": 0.0, "last": 0.0, "seam_delta": 0.0, "tail_rms": 0.0, "zcr_hz": 0.0, "low_ratio": 0.0,
			"has_nan": false, "hash": "",
		}
	var bytes := wav.data
	var n := bytes.size() / 2
	var sr := maxi(wav.mix_rate, 1)
	var sum := 0.0
	var sum_sq := 0.0
	var peak := 0.0
	var first := 0.0
	var last := 0.0
	var crossings := 0
	var prev := 0.0
	var tail_n := clampi(int(round(0.005 * float(sr))), 1, maxi(n, 1))
	var tail_start := maxi(n - tail_n, 0)
	var tail_sq := 0.0
	# 1-pole 400 Hz low-pass filter to measure low-frequency (<400 Hz) energy share.
	var inv_sr := 1.0 / float(sr)
	var rc := 1.0 / (TAU * 400.0)
	var lp_a := inv_sr / (rc + inv_sr)
	var lp := 0.0
	var low_sq := 0.0
	for i in n:
		var lo := int(bytes[i * 2])
		var hi := int(bytes[i * 2 + 1])
		var u := lo | (hi << 8)
		if u >= 32768:
			u -= 65536
		var f := float(u) / 32768.0
		if i == 0:
			first = f
		elif (prev < 0.0 and f >= 0.0) or (prev >= 0.0 and f < 0.0):
			crossings += 1
		prev = f
		last = f
		sum += f
		sum_sq += f * f
		peak = maxf(peak, absf(f))
		if i >= tail_start:
			tail_sq += f * f
		lp += lp_a * (f - lp)
		low_sq += lp * lp
	var rms := sqrt(sum_sq / float(maxi(n, 1)))
	var mean := sum / float(maxi(n, 1))
	var tail_rms := sqrt(tail_sq / float(maxi(n - tail_start, 1)))
	var zcr_hz := (float(crossings) * float(sr)) / (2.0 * float(maxi(n, 1)))
	var low_ratio := low_sq / maxf(sum_sq, 1e-12)
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	var digest := ctx.finish().hex_encode().substr(0, 16)
	return {
		"samples": n,
		"duration": float(n) / float(sr),
		"rms": rms,
		"rms_db": linear_to_db(maxf(rms, 1e-6)),
		"peak": peak,
		"mean": mean,
		"first": first,
		"last": last,
		"seam_delta": absf(last - first),
		"tail_rms": tail_rms,
		"zcr_hz": zcr_hz,
		"low_ratio": low_ratio,
		"has_nan": is_nan(rms) or is_nan(peak) or is_nan(mean),
		"hash": digest,
	}


static func _osc(p: float, wave: String) -> float:
	match wave:
		"tri":
			return 4.0 * absf(p - 0.5) - 1.0
		"saw":
			return 2.0 * p - 1.0
		"square":
			return 1.0 if p < 0.5 else -1.0
		"sub":
			return sin(TAU * p) * 0.8 + sin(TAU * p * 2.0) * 0.2
		_:
			return sin(TAU * p)


static func _env(t: float, dur: float, atk: float, rel: float) -> float:
	var e := 1.0
	if t < atk:
		e = t / atk
	var rem := dur - t
	if rem < rel:
		e = minf(e, maxf(rem / rel, 0.0))
	return e
