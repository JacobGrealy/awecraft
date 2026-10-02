extends Node
# AC-0039 — the procedural sound layer. WS8: no audio asset files; every
# sound is SYNTHESIZED in code to 16-bit PCM at RATE and cached as an
# AudioStreamWAV at startup (one generation, zero per-event allocation).
#
# Design notes (see tasks/AC-0039/AC-0039-results.html for the parameter
# table):
#  - 9 base voices: block, step, hit, eat, splash, arrow, bow, mob, ambient.
#  - Every call site in the codebase already calls Audio.play("<name>") with
#    a set of names wider than the 9 bases (break/place/door/hurt/pickup/
#    gorilla). _ALIAS routes those to the closest base voice so NO existing
#    event goes silent; the 9 bases are the only things actually generated.
#  - ALL voices are NON-positional AudioStreamPlayers (a 2D SFX bed). No
#    positional audio exists, so the sphere-frame / radial-up convention
#    does not apply here; if positional sound is added later it MUST follow
#    the DayNight/radial-up rules (see arrow.gd's radial gravity).
#  - Concurrency = a fixed pool of VOICE_POOL AudioStreamPlayers, round-robin,
#    preempt-oldest on cap (the AC-0038 pooled-particle discipline). The
#    allocation counter proves play() never grows the tree.
#  - The synth functions are pure + deterministic (fixed seed per voice), so
#    the headless arm can call them directly and assert on the GENERATED
#    buffer, not just that a call returned.

const RATE := 22050
const VOICE_POOL := 16
# The 9 base voices actually synthesized (the spec's list).
const BASES := ["block", "step", "hit", "eat", "splash", "arrow", "bow", "mob", "ambient"]
# Call-site names wider than the 9 bases -> nearest base (keeps them audible).
const _ALIAS := {
	"break": "block",
	"place": "block",
	"door": "block",
	"hurt": "hit",
	"pickup": "hit",
	"gorilla": "mob",
}

var volume := 100.0

var _pool: Array = []        # AudioStreamPlayer, fixed size VOICE_POOL
var _next := 0               # round-robin cursor
var _busy := []              # parallel bool, which voices are playing
var _steals := 0             # preemptions at the cap (round-robin overwrite)
var _ambient_player: AudioStreamPlayer = null  # the looping ambient bed
var _streams := {}           # base name -> AudioStreamWAV (cached)
var _floats := {}            # base name -> PackedFloat32Array (the generated PCM)
var _allocs := 0             # nodes created (proves play() is allocation-free)
var _plays := {}             # name -> trigger count (arm proves triggers fire)
var _peak_live := 0          # max concurrent playing voices seen


func _ready() -> void:
	# Generate every base voice ONCE and cache it. Startup cost only.
	for nm in BASES:
		var f: PackedFloat32Array = synth(nm)
		_floats[nm] = f
		_streams[nm] = _to_wav(nm, f)
	# The fixed voice pool — allocated once, reused round-robin forever.
	for i in VOICE_POOL:
		var p := AudioStreamPlayer.new()
		_allocs += 1
		p.finished.connect(_on_voice_done.bind(i))
		add_child(p)
		_pool.append(p)
		_busy.append(false)
	# The ambient bed: ONE extra player (outside the SFX pool), the 2 s wind
	# loop on LOOP_FORWARD, quiet (-14 dB). Non-positional: a global bed, so
	# no sphere-frame / world-axis assumption is involved.
	_ambient_player = AudioStreamPlayer.new()
	_allocs += 1
	_ambient_player.stream = _streams["ambient"]
	_ambient_player.volume_db = -14.0
	add_child(_ambient_player)
	_ambient_player.play()
	apply()


func set_volume(v) -> void:
	volume = clampf(float(v), 0.0, 100.0)
	apply()


func apply() -> void:
	var idx := AudioServer.get_bus_index("Master")
	if idx >= 0:
		AudioServer.set_bus_volume_db(idx, linear_to_db(volume / 100.0))


# Resolve a call-site name to a base voice. Unknown names fall back to the
# neutral "hit" thud so a typo can never be a silent event (the one outcome
# the spec says is worse than not starting).
func _base(name: String) -> String:
	if _streams.has(name):
		return name
	var a = _ALIAS.get(name)
	if a != null:
		return str(a)
	return "hit"


# Play a named sound. NO allocation: picks a pooled player, preempts it if
# still busy (round-robin = oldest-first in a steady stream), sets the
# cached stream, plays.
func play(name) -> void:
	_plays[str(name)] = int(_plays.get(str(name), 0)) + 1
	var base := _base(str(name))
	# The ambient bed is a LOOP: it must never occupy an SFX pool voice
	# (a looping stream on a one-shot voice would hold the slot forever —
	# exactly the leak the fixed pool exists to prevent). Route it to the
	# dedicated bed player instead.
	if base == "ambient":
		if _ambient_player != null and not _ambient_player.playing:
			_ambient_player.play()
		return
	var i := _next
	_next = (_next + 1) % VOICE_POOL
	var p: AudioStreamPlayer = _pool[i]
	if _busy[i]:
		p.stop()  # preempt the oldest in the ring (cap policy)
		_steals += 1
	p.stream = _streams[base]
	p.volume_db = 0.0
	p.play()
	_busy[i] = true
	var live := 0
	for b in _busy:
		if b:
			live += 1
	_peak_live = max(_peak_live, live)


func _on_voice_done(i: int) -> void:
	if i >= 0 and i < _busy.size():
		_busy[i] = false


func alloc_count() -> int:
	return _allocs


func pool_size() -> int:
	return VOICE_POOL


func play_count(name: String) -> int:
	return int(_plays.get(name, 0))


func peak_live() -> int:
	return _peak_live


func live_now() -> int:
	var s := 0
	for b in _busy:
		if b:
			s += 1
	return s


func steals() -> int:
	return _steals


func ambient_playing() -> bool:
	return _ambient_player != null and _ambient_player.playing


# ---------------------------------------------------------------- synth ----
# Pure + deterministic: synth(name) -> mono PackedFloat32Array in [-1, 1] at
# RATE. A fixed RNG seed per voice makes every call byte-identical, which is
# what lets the headless arm assert on the buffer contents.

static func synth(name: String) -> PackedFloat32Array:
	var f: PackedFloat32Array
	match name:
		"block":
			f = _synth_block()
		"step":
			f = _synth_step()
		"hit":
			f = _synth_hit()
		"eat":
			f = _synth_eat()
		"splash":
			f = _synth_splash()
		"arrow":
			f = _synth_arrow()
		"bow":
			f = _synth_bow()
		"mob":
			f = _synth_mob()
		"ambient":
			f = _synth_ambient()
		_:
			f = _synth_hit()
	# Loudness safety (a shape-preserving limiter): keep every generated
	# buffer within 0.9 peak headroom, so "no clipping" is a real property
	# of the synth output — not an artifact of the 16-bit clamp in _to_wav.
	var peak := 0.0
	for i in f.size():
		peak = maxf(peak, absf(f[i]))
	if peak > 0.9:
		var g := 0.9 / peak
		for i in f.size():
			f[i] *= g
	return f


# A seeded white-noise helper (deterministic per seed).
static func _noise(n: int, seed: int) -> PackedFloat32Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		out[i] = rng.randf_range(-1.0, 1.0)
	return out


static func _env_exp(n: int, tau: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		out[i] = exp(-float(i) / (RATE * tau))
	return out


# 1. BLOCK — a short "thock": 85 Hz decaying tone + a 6 ms noise crackle.
#    Duration 0.16 s. Distinguished by a single low tone with a noise tip.
static func _synth_block() -> PackedFloat32Array:
	var dur := 0.16
	var n := int(RATE * dur)
	var tone := PackedFloat32Array()
	tone.resize(n)
	var phase := 0.0
	for i in n:
		phase += TAU * 85.0 / RATE
		tone[i] = sin(phase)
	var env := _env_exp(n, 0.05)
	var out := PackedFloat32Array()
	out.resize(n)
	var crack := _noise(int(RATE * 0.006), 101)
	for i in n:
		var c := crack[i] if i < crack.size() else 0.0
		out[i] = tone[i] * env[i] * 0.85 + c * 0.35 * (env[i] if i < crack.size() else 0.0)
	return out


# 2. STEP — a footfall: 60 Hz thud, very short (0.09 s), quiet (0.5 gain).
static func _synth_step() -> PackedFloat32Array:
	var dur := 0.09
	var n := int(RATE * dur)
	var tone := PackedFloat32Array()
	tone.resize(n)
	var phase := 0.0
	for i in n:
		phase += TAU * 60.0 / RATE
		tone[i] = sin(phase)
	var env := _env_exp(n, 0.025)
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		out[i] = tone[i] * env[i] * 0.5
	return out


# 3. HIT — damage: a 220 Hz -> 70 Hz falling sweep (0.22 s) + a noise burst.
#    The pitch drop is the fingerprint vs the flat block thock.
static func _synth_hit() -> PackedFloat32Array:
	var dur := 0.22
	var n := int(RATE * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	var phase := 0.0
	var noise := _noise(n, 103)
	for i in n:
		var f: float = lerpf(220.0, 70.0, float(i) / float(n))
		phase += TAU * f / RATE
		out[i] = sin(phase) * 0.7
	var env := _env_exp(n, 0.06)
	var burst := _noise(int(RATE * 0.03), 104)
	for i in n:
		out[i] *= env[i]
		if i < burst.size():
			out[i] += burst[i] * 0.3 * env[i]
	return out


# 4. EAT — two crunch pulses: 150 Hz tone gated by a 20 Hz amplitude wobble
#    over 0.3 s, plus a noise "crunch" bed. Distinguished by the wobble.
static func _synth_eat() -> PackedFloat32Array:
	var dur := 0.30
	var n := int(RATE * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	var phase := 0.0
	var noise := _noise(n, 105)
	for i in n:
		var t := float(i) / RATE
		phase += TAU * 150.0 / RATE
		var wob := 0.5 + 0.5 * sin(TAU * 20.0 * t)
		var gate := maxf(0.0, sin(TAU * 2.2 * t))  # two chewing pulses
		out[i] = sin(phase) * wob * gate * 0.6 + noise[i] * 0.18 * gate
	var env := _env_exp(n, 0.09)
	for i in n:
		out[i] *= env[i]
	return out


# 5. SPLASH — water: bandpass-ish noise (white passed through a one-pole LP
#    at ~1.2 kHz) with a slow downward wobble, 0.4 s. Noise-dominant = the
#    fingerprint vs every tone-based voice.
static func _synth_splash() -> PackedFloat32Array:
	var dur := 0.40
	var n := int(RATE * dur)
	var white := _noise(n, 106)
	var lp := PackedFloat32Array()
	lp.resize(n)
	var alpha := 1.0 - exp(-TAU * 1200.0 / RATE)
	var s := 0.0
	for i in n:
		s += alpha * (white[i] - s)
		lp[i] = s
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var t := float(i) / RATE
		var wob := 0.7 + 0.3 * sin(TAU * 5.0 * t)
		out[i] = lp[i] * wob * 0.9
	var env := _env_exp(n, 0.12)
	for i in n:
		out[i] *= env[i]
	return out


# 6. ARROW — a "thwip": rising-band noise whoosh (one-pole LP whose corner
#    rises 300 -> 4000 Hz) then a short low thud on landing. 0.30 s.
static func _synth_arrow() -> PackedFloat32Array:
	var dur := 0.30
	var n := int(RATE * dur)
	var white := _noise(n, 107)
	var out := PackedFloat32Array()
	out.resize(n)
	var s := 0.0
	var thud_n := int(RATE * 0.03)
	var thud := _noise(thud_n, 108)
	for i in n:
		var frac := float(i) / float(n)
		var f: float = lerpf(300.0, 4000.0, frac)
		var a := 1.0 - exp(-TAU * f / RATE)
		s += a * (white[i] - s)
		out[i] = s * 0.7 * (1.0 - frac * 0.5)
	# landing thud at the tail
	var off := n - thud_n
	var tp := 0.0
	for i in thud_n:
		tp += TAU * 90.0 / RATE
		out[off + i] += sin(tp) * exp(-float(i) / (RATE * 0.01)) * 0.7
	return out


# 7. BOW — a string twang: a 320 Hz pluck (fast decay) + a short creaking
#    noise, 0.35 s. Distinguished by the single mid pluck + low noise.
static func _synth_bow() -> PackedFloat32Array:
	var dur := 0.35
	var n := int(RATE * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	var phase := 0.0
	var creak := _noise(int(RATE * 0.05), 109)
	for i in n:
		phase += TAU * 320.0 / RATE
		out[i] = sin(phase) * 0.8
	var env := _env_exp(n, 0.05)
	for i in n:
		out[i] *= env[i]
	for i in min(creak.size(), n):
		out[i] += creak[i] * 0.25
	return out


# 8. MOB — a growl: a 95 Hz sawtooth with a 7 Hz amplitude growl-wobble,
#    0.3 s. The sawtooth (harmonics) + wobble is the fingerprint.
static func _synth_mob() -> PackedFloat32Array:
	var dur := 0.30
	var n := int(RATE * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	var phase := 0.0
	for i in n:
		var t := float(i) / RATE
		phase = fmod(phase + TAU * 95.0 / RATE, TAU)
		var saw := phase / TAU * 2.0 - 1.0
		var wob := 0.5 + 0.5 * sin(TAU * 7.0 * t)
		out[i] = saw * wob * 0.6
	var env := _env_exp(n, 0.08)
	for i in n:
		out[i] *= env[i]
	return out


# 9. AMBIENT — a 2.0 s seamless wind loop: 3 integer-period sines (guaranteed
#    to loop) + Hann-windowed noise (zero at both ends -> seamless). Kept
#    quiet; the arm asserts it loops and is non-silent.
static func _synth_ambient() -> PackedFloat32Array:
	var dur := 2.0
	var n := int(RATE * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	# k cycles across n samples => k/dur Hz, an integer cycle count, so the
	# tone is seamless at the loop point: 1 + 2.5 + 5.5 Hz rumble and a
	# 55 Hz hum (110 cycles over 2 s).
	for i in n:
		out[i] = 0.5 * sin(TAU * 2.0 * float(i) / n) \
				+ 0.3 * sin(TAU * 5.0 * float(i) / n) \
				+ 0.15 * sin(TAU * 11.0 * float(i) / n) \
				+ 0.12 * sin(TAU * 110.0 * float(i) / n)
	# Wind body: Hann-windowed white noise (zero at both ends => seamless seam)
	var noise := _noise(n, 110)
	for i in n:
		var w := 0.5 - 0.5 * cos(TAU * float(i) / float(n - 1))
		out[i] += noise[i] * w * 0.35
	return out


# ----------------------------------------------------------------- wav -----
static func _to_wav(name: String, f: PackedFloat32Array) -> AudioStreamWAV:
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	var bytes := PackedByteArray()
	bytes.resize(f.size() * 2)
	for i in f.size():
		var v := int(clampf(f[i], -1.0, 1.0) * 32767.0)
		bytes[i * 2] = v & 0xFF
		bytes[i * 2 + 1] = (v >> 8) & 0xFF
	w.data = bytes
	if name == "ambient":
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = f.size()
	return w


# Expose the generated PCM for the headless arm (assert on the buffer).
func floats(name: String) -> PackedFloat32Array:
	return _floats.get(_base(str(name)), PackedFloat32Array())


func stream(name: String) -> AudioStreamWAV:
	return _streams.get(_base(str(name)), null)
