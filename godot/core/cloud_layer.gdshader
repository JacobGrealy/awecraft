shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled;
// (the dummy/headless renderer rejects `transparent` and logs a
// SHADER ERROR - the same accepted condition satellite_body.gdshader
// has lived with since AC-0310; the shipped forward_plus compiles it.)

// AC-0235: the procedural cloud layer (replaces the clouds that the old
// AeroSky dome painted in view-direction space). AC-0385: the layer is now
// a SPHERICAL SHELL around the planet (three concentric SphereMeshes at
// R + 275 / 330 / 400, centred at (0, -R, 0) - the same altitudes the old
// quads hovered at) instead of three flat 6144/5120/4096-block quads that
// followed the player's XZ. From orbit the old quads read as sparse puffs
// on a flat sheet (3.1-5.7% of the planet disc had day alpha > 0.2 at any
// altitude - tasks/AC-0385/AC-0385-results.html); the shell wraps the
// planet (67.8% of the globe, even across latitude bands).
// The PATTERN is still world-anchored: it is sampled on the unit direction
// from the planet centre, so it parallaxes correctly and scrolls by a
// rotation about world Y (u_drift * u_cloud_time; main.gd advances
// u_cloud_time each frame and derives u_drift from the old per-layer wind,
// so the drift speeds are the old ones in blocks/sec, now angular).
// The feature sizes stay in BLOCKS (u_scale3 = 2*pi*(R+h)/feature is set
// by main.gd per layer). Fog stays disabled (depth fog is tuned for the
// local 238-714 m band; a 4300 m shell would be erased by it).
// AC-0385 coverage: the old window smoothstep(0.62, 0.88, base) sat 1.3
// std above the fbm mean (0.485, std 0.107) - that is what made the puffs
// sparse. The window is now 0.50-0.58 (+0.14 to +0.79 std) and the fine
// octave modulates the alpha (in AC-0235 it was computed into `n` and
// never used). Day coverage is 67.8% of the globe at alpha > 0.2 (bands
// 66.6-68.3%; longest clear streak p95 7.2 deg), night 37.3%.
// AC-0384 r8: the window moves to 0.46-0.54 (centred on the mean) and
// the latitude banding to 5 cycles with a 0.75 floor, so the mid-
// latitude belt - the only part of the deck a descending player sees
// from inside the shells - carries clearly visible cloud (the r6 window
// left it at 0.19% pattern at CLOUD_T0=411200). Globe coverage is
// re-measured in the ticket's coverage probe (results §23).
// AC-0384 r9 (round 6): the sustained descent passage. r8b made the
// belt VISIBLE, but the three shells still sampled ONE shared field at
// their three feature scales, so a clear phase of that field cleared
// all three decks at once - the deck read as ONE thin band (the round-5
// census: 1600/700 m at 0.000% at CLOUD_T0=411200, the belt limb in a
// clear phase at every one of the six clock values scanned). Two
// levers, both here: (1) each shell now samples the field at its OWN
// lattice offset (u_phase, pushed per shell by main.gd; the top shell
// keeps 0), so the decks carry independent structured coverage and a
// clear phase of one deck's pattern no longer clears the others; (2)
// the coverage window's lower bound moves 0.46 -> 0.42, so a
// below-mean coarse phase (the ~0.45 descent-cap field at the
// reference weather) still carries structured cloud - the effective
// threshold lands at ~0.464 on the top shell, inside the field's
// one-sigma band, at every observed weather. Together: a descending
// player is inside cloud structure over the whole 275-400 m band.
// Shell radii/centre/transforms are untouched.
// AC-0385 lighting: lit by the SAME DayNight.sun_direction convention
// AC-0382 wired into the satellite body (u_sun = direction TO the sun;
// u_day = 0.18 + 0.82*day; u_day_gain = 0.82*day - the satellite's exact
// uniform set, pushed per frame by main.gd). Lighting multiplies the
// ALBEDO, never the ALPHA - the weather coverage is a function of world
// direction and time-of-day only, so the shell can never pop as the
// player moves or climbs (the no-pop argument at the satellite body's
// emergence). The grazing fade thins the mass to the silhouette, where
// the body's own limb haze is strongest (no double-counted white rim).
// AC-0384 r6: the NMS read - thick, banded, OCCLUDING decks with visible
// depth and darker undersides, from orbit AND from below/inside the
// layer. Changes vs r5: (1) cull_back -> cull_disabled + fragment-stage
// cull emulation (the rasterizer cull killed the whole underside view;
// with cull off the far side would draw through the near side in the
// transparent pass, so back faces are discarded only while the camera is
// outside the shell - the orbit view is unchanged by construction);
// (2) broad warped latitude bands modulate the alpha (NMS banding);
// (3) a soft bimodal contrast window (0.05/0.80) turns the haze/clear
// split into thin veil vs opaque cores; (4) u_boost 2.0 clamps the dense
// cores to full opacity (occlusion); (5) darker undersides - the albedo
// darkens with optical thickness (u_under 0.70).
// AC-0405: the RAYMARCHED VOLUME (u_vol > 0.5, Settings "cloud_volume",
// default ON - the user ordered the rework: "look at how voluminous
// clouds are done and implement them, forget how we currently do it").
// Four rounds of patterned-surface work (AC-0385/0384 r6-r10/AC-0401)
// could not make the deck read as a volume: a single surface at a single
// radius has no parallax and no internal depth. The rework is structural:
// the pattern becomes a DENSITY FIELD and the surface becomes a VOLUME -
// the fragment raymarches the annulus [R+275, R+400] about the centre
// (the SAME verified shell extent; the outer shell carries the march, the
// two inner shells are hidden by world.gd, geometry untouched) through a
// 3-D FBM field (the same ahash/anv noise, the same deck windows and
// banding as the 2-D path above, now sampled in 3-D so structure varies
// through the layer thickness), accumulates Beer's-law transmittance, and
// lights each sample with a SHORT MARCH TOWARD THE SUN through the same
// field (self-shadow: a top sample's march exits the cloud -> bright, an
// underside sample's stays inside -> dark), a Henyey-Greenstein phase for
// the forward-scatter rim toward the sun, and a dark-edge term that keeps
// camera-facing boundaries from reading as grey mush (the Guerrilla HZD
// powder/dark-edge role). The reference implementation read per the
// ticket: godotshaders.com "Volumetric Raymarched (animated) Clouds v2"
// (slab intersection + count-based steps), the Guerrilla SIGGRAPH ARTR
// talk (the lighting model). u_vol < 0.5 short-circuits before any of
// the work: the three-shell path below is byte-identical to AC-0401.
// The entry of the volume path sits IN fragment() (not a helper): the
// dummy parser resolves the fragment builtins and `discard` in the
// fragment function only (measured - a nested entry failed G0), so the
// helpers below are builtin-free and return by value.
uniform vec3 u_center = vec3(0.0, -4000.0, 0.0);  // planet centre (main.gd)
uniform float u_scale3 = 107.92;  // 2*pi*(R+h)/feature, per layer (main.gd)
uniform float u_drift = 0.00122;  // rad/s about world Y, per layer (main.gd)
// AC-0384 r9 (round 6): per-shell pattern offset in the noise lattice -
// each deck carries its OWN structured coverage (main.gd pushes a
// constant per shell; 0 = the shared-field pattern of r8b and earlier,
// where a clear phase of the field cleared all three decks at once -
// the "one thin band" descent). The latitude banding stays shared (it
// is built on dr.y), so the decks keep aligned belts while the pattern
// within each belt is per-layer.
uniform vec3 u_phase = vec3(0.0);
uniform float u_cloud_time = 0.0;
uniform float u_coverage : hint_range(0.0, 1.0) = 0.5;
uniform vec3 u_cloud_tint : source_color = vec3(1.0);
uniform vec3 u_sun = vec3(0.0, 1.0, 0.0);
uniform float u_day : hint_range(0.0, 2.0) = 1.0;
uniform float u_day_gain : hint_range(0.0, 2.0) = 0.82;
// AC-0242: unshaded output needs the compat pre-decode like the chunks.
uniform float u_srgb_pre : hint_range(0.0, 1.0) = 0.0;
// AC-0384 r5: screen scale for the noise field's distance LOD (px per
// radian at the current window size and camera fov). main.gd pushes it
// per frame; the default is the 1280x720 harness window (720 /
// (2*tan(37.5 deg)) - the 75 deg camera fov).
uniform float u_cpxrad : hint_range(50.0, 4000.0) = 476.0;
// AC-0384 r6: opacity boost - the dense cores clamp to 1.0 (the deck
// occludes the sky/terrain behind it, the NMS "thick cloud" read).
// AC-0384 r8 (one tuning iteration, coordinator-sanctioned): 2.0 -> 2.2 -
// the r8 window (0.45-0.53) leaves the field's mid values thin, so the
// cores need a little more boost to read as OCCLUDING cloud from inside
// the shells (the descent view).
uniform float u_boost : hint_range(0.0, 4.0) = 2.2;
// AC-0384 r6: underside darkening - the albedo of an optically thick
// fragment is multiplied by u_under (the thinner the patch, the closer
// to 1.0 - the full sun-lit albedo).
uniform float u_under : hint_range(0.0, 1.0) = 0.70;
// AC-0401: the deck character switch (Settings "cloud_deck", default ON;
// world.gd pushes u_deck = 1.0 when ON). 0.0 (the shader default - no
// push, e.g. any material built without the world push) is the exact
// pre-AC-0401 path: the r9 field at full frequency and the r8/r9
// windows, bit-identical. 1.0 is the character the user asked for -
// "fewer of them but the individual clouds should be bigger and they
// should be volumetric": the base field at 1/3 frequency (the masses
// ~3x wider), a higher coverage window (fewer), a lower band floor
// (real clear gaps between the belts instead of 75% carry), softer edge
// windows, and a volumetric read - puff brightness off the mid field
// plus stronger thickness darkening so the masses read as lit-from-
// above with deep cores, not as a flat membrane.
uniform float u_deck : hint_range(0.0, 1.0) = 0.0;
// AC-0405: the raymarched-volume switch + parameters (world.gd
// _ac0401_push pushes u_vol / u_vol_r / u_vol_rmin / u_vol_rmax; the
// step/sigma/edge/phase values are the shipped tuning - the cost knobs
// are u_vol_steps and u_vol_lsteps). All defaults are the OFF state:
// u_vol 0.0 short-circuits fragment() before any volume work, so a
// material that never sees the push keeps the exact three-shell deck.
uniform float u_vol : hint_range(0.0, 2.0) = 0.0;
uniform float u_vol_r : hint_range(100.0, 20000.0) = 4000.0;      // planet R
uniform float u_vol_rmin : hint_range(0.0, 20000.0) = 4275.0;     // R+275
uniform float u_vol_rmax : hint_range(0.0, 20000.0) = 4400.0;     // R+400
uniform float u_vol_steps : hint_range(1.0, 64.0) = 24.0;         // view steps per segment
uniform float u_vol_lsteps : hint_range(1.0, 16.0) = 6.0;         // light-march taps (coarse)
uniform float u_vol_sigma : hint_range(0.001, 0.05) = 0.01;       // extinction /m at d=1
uniform float u_vol_edge : hint_range(0.0, 1.0) = 0.55;           // dark-edge strength
uniform float u_vol_hg : hint_range(-0.9, 0.9) = 0.65;            // HG anisotropy

varying vec3 v_wp;  // world position (spatial shaders have no WORLD_POSITION builtin)

void vertex() {
	v_wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fog_fragment() {
}

float ahash(vec3 p) {
	p = fract(p * vec3(234.34, 435.345, 341.345));
	p += dot(p, p + 34.23);
	return fract(p.x * p.y * p.z);
}

float anv(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float c000 = ahash(i);
	float c100 = ahash(i + vec3(1.0, 0.0, 0.0));
	float c010 = ahash(i + vec3(0.0, 1.0, 0.0));
	float c110 = ahash(i + vec3(1.0, 1.0, 0.0));
	float c001 = ahash(i + vec3(0.0, 0.0, 1.0));
	float c101 = ahash(i + vec3(1.0, 0.0, 1.0));
	float c011 = ahash(i + vec3(0.0, 1.0, 1.0));
	float c111 = ahash(i + vec3(1.0, 1.0, 1.0));
	float x00 = mix(c000, c100, f.x);
	float x10 = mix(c010, c110, f.x);
	float x01 = mix(c001, c101, f.x);
	float x11 = mix(c011, c111, f.x);
	return mix(mix(x00, x10, f.y), mix(x01, x11, f.y), f.z);
}

// 5 octaves, same structure as the old 2-D fbm (AC-0235 retest 5).
float fbm(vec3 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) {
		v += a * anv(p);
		p = p * 2.03 + vec3(17.1, 9.2, 4.7);
		a *= 0.5;
	}
	return v;
}

// ---- AC-0405: the raymarched volume (used only when u_vol > 0.5) ----
// Builtin-free helpers (the fragment builtins and `discard` resolve in
// fragment() only on the dummy parser - measured, G0), return by value.

// The base wavenumber in unit-sphere coordinates: exactly the 256 m base
// period of THIS shell's 2-D path (u_scale3 = TAU*rsh/scale -> 2*pi/scale
// angular; on unit coordinates about the planet centre that is
// TAU*R/scale = u_scale3 * R / rsh, and rsh of the marching shell is
// u_vol_rmax). The deck switch divides it by 3 exactly as the 2-D path.
float vsc3() {
	return u_scale3 * u_vol_r / u_vol_rmax;
}

// World position -> wind-rotated planet-frame unit-sphere coordinate.
// NOT renormalised: |q| runs 1.069..1.10 through the annulus, so the
// field genuinely varies through the layer thickness (vertical
// structure - one of the two acceptance properties).
vec3 vrot(vec3 p, float ca, float sa) {
	vec3 q = (p - u_center) / u_vol_r;
	return vec3(ca * q.x + sa * q.z, q.y, -sa * q.x + ca * q.z);
}

// 3-octave fbm on the volume lattice (the 2-D path's 5 octaves collapse
// to 3 in 3-D: the per-tap cost triples, and the count-based march
// over-integrates the fine octaves at distance, so 3 is the budgeted
// structure).
float vfbm3(vec3 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 3; i++) {
		v += a * anv(p);
		p = p * 2.03 + vec3(17.1, 9.2, 4.7);
		a *= 0.5;
	}
	return v;
}

// The radial gate: the field is CONFINED to the annulus. Without it the
// FBM fills all of space around the shell and the light march (480 m
// toward the sun) and the dark-edge tap never see clear sky - every
// sample self-shadows and the whole deck reads as one dark storm band
// (measured on the first 700 m pair, pre-gate: the band sat at ~60-90
// luminance with no lit tops). With the gate the light march exits the
// deck in ~125 m at a top sample (lit tops), stays inside for an
// underside sample (dark undersides), and the view-march chord ends in
// a ~20 m smooth fade instead of a hard segment cut (soft deck edges).
// (Defined before vdens: GLSL has no forward declarations.)
float vgate(vec3 q) {
	float r = length(q);
	float rmin_q = u_vol_rmin / u_vol_r;
	float rmax_q = u_vol_rmax / u_vol_r;
	float m = 0.005;  // ~20 m at R = 4000
	return smoothstep(rmin_q - m, rmin_q + m, r)
		* (1.0 - smoothstep(rmax_q - m, rmax_q + m, r));
}

// The FULL 3-D density (0..1): the EXACT window chain of the 2-D path
// (u_deck-parameterised, byte-identical constants), now in 3-D. The fine
// octave's 0.85+0.15 modulation is dropped in 3-D (the octaves inside
// vfbm3 carry the detail; the tap budget does not carry a fourth field).
float vdens(vec3 q) {
	float sc3 = vsc3();
	float wlo = 0.42, whi = 0.54;
	float cehi = 0.55;
	float bfloor = 0.75, blo = 0.18, bhi = 0.82;
	float elow = 0.05, ehi = 0.80;
	if (u_deck > 0.5) {
		sc3 = sc3 * 0.33333;
		wlo = 0.46; whi = 0.56;
		cehi = 0.70;
		bfloor = 0.60; blo = 0.30; bhi = 0.90;
		elow = 0.00; ehi = 0.90;
	}
	float base = vfbm3(q * sc3 + u_phase);
	float mid = vfbm3(q * sc3 * 2.2 + vec3(13.7, 7.3, 5.9));
	float cl = smoothstep(wlo, whi, base);
	cl = smoothstep(0.0, cehi, cl) * cl;
	cl *= bfloor + (1.0 - bfloor) * (0.55 * base + 0.45 * mid);
	float band = 0.5 + 0.5 * sin(q.y * 5.0 + 2.2 * base);
	cl *= mix(bfloor, 1.0, smoothstep(blo, bhi, band));
	cl = smoothstep(elow, ehi, cl);
	return cl * vgate(q);
}

// The COARSE density (1 octave + band, same windows): the light march
// and the dark-edge tap do not need the fine octaves (shadows and edges
// are large-scale), and this is the cost lever that keeps the light
// march cheap.
float vdens_coarse(vec3 q) {
	float sc3 = vsc3();
	float wlo = 0.42, whi = 0.54;
	float bfloor = 0.75, blo = 0.18, bhi = 0.82;
	float elow = 0.05, ehi = 0.80;
	if (u_deck > 0.5) {
		sc3 = sc3 * 0.33333;
		wlo = 0.46; whi = 0.56;
		bfloor = 0.60; blo = 0.30; bhi = 0.90;
		elow = 0.00; ehi = 0.90;
	}
	float base = anv(q * sc3 + u_phase);
	float cl = smoothstep(wlo, whi, base);
	float band = 0.5 + 0.5 * sin(q.y * 5.0 + 2.2 * base);
	cl *= mix(bfloor, 1.0, smoothstep(blo, bhi, band));
	cl = smoothstep(elow, ehi, cl);
	return cl * vgate(q);
}

// Henyey-Greenstein phase (the 4*pi normalisation folds into the gains).
float vhg(float cosang) {
	float g = u_vol_hg;
	float g2 = g * g;
	float d = 1.0 + g2 - 2.0 * g * cosang;
	return (1.0 - g2) / (d * sqrt(max(d, 0.001)));
}

// Sphere intersection: the roots of |w + rd*t| = r as vec4(t1, t2, hit,
// 0) with t1 <= t2; hit 0 for no real root.
vec4 vsphere_roots(vec3 w, vec3 rd, float r) {
	float b = dot(rd, w);
	float c = dot(w, w) - r * r;
	float disc = b * b - c;
	float hit = step(0.0, disc);
	float sq = sqrt(max(disc, 0.0));
	return vec4(-b - sq, -b + sq, hit, 0.0);
}

// The annulus [rmin, rmax] is where the density lives. A view ray
// crosses it in ONE interval (most views) or TWO (near-side + far-side
// of the limb, views that pass through the inner ball). Each segment
// builder returns vec2(t0, t1); t1 < t0 marks an empty segment.
vec2 vseg1(vec3 w, vec3 rd, float rc) {
	vec4 rO = vsphere_roots(w, rd, u_vol_rmax);
	vec4 rI = vsphere_roots(w, rd, u_vol_rmin);
	float tO1 = rO.x;
	float tO2 = rO.y;
	float tI1 = rI.x;
	float tI2 = rI.y;
	if (rc > u_vol_rmax) {
		// camera outside the outer sphere: the near-side annulus runs
		// from the outer entry to the inner entry (the whole chord if
		// the ray misses the inner ball).
		if (rI.z > 0.5) {
			return vec2(tO1, tI1);
		}
		return vec2(tO1, tO2);
	} else if (rc > u_vol_rmin) {
		// camera inside the annulus: from 0 to the inner entry (if the
		// ray reaches the inner ball), else to the outer exit.
		if (rI.z > 0.5 && tI1 > 0.0) {
			return vec2(0.0, tI1);
		}
		return vec2(0.0, tO2);
	} else {
		// camera inside the inner ball: both spheres are exited forward
		// (the product of the roots is < 0, so each quadratic has
		// exactly one positive root); the annulus runs between the
		// inner exit and the outer exit (the inner ball is nested, so
		// the inner exit always precedes the outer one).
		return vec2(min(tI2, tO2), max(tI2, tO2));
	}
}

vec2 vseg2(vec3 w, vec3 rd, float rc) {
	vec4 rO = vsphere_roots(w, rd, u_vol_rmax);
	vec4 rI = vsphere_roots(w, rd, u_vol_rmin);
	float tO1 = rO.x;
	float tO2 = rO.y;
	float tI1 = rI.x;
	float tI2 = rI.y;
	if (rc > u_vol_rmax) {
		// the far side of the limb, only when the ray reaches the inner
		// ball: from the inner exit to the outer exit.
		if (rI.z > 0.5) {
			return vec2(tI2, tO2);
		}
		return vec2(-1.0, -2.0);
	} else if (rc > u_vol_rmin) {
		// camera in the annulus, ray aimed at the inner ball: the far
		// side runs from the inner exit to the outer exit.
		if (rI.z > 0.5 && tI2 > 0.0) {
			return vec2(tI2, tO2);
		}
		return vec2(-1.0, -2.0);
	}
	return vec2(-1.0, -2.0);
}

// March one segment, carrying the Beer transmittance T in and returning
// vec4(T, L, Lo, 0): L is the in-scatter (sun -> sample -> camera,
// self-shadowed, dark-edged), Lo the out-scatter (the faint rim
// opposite the sun). The step is length/count: distance-adaptive by
// construction (a 1700 m limb chord gets ~70 m steps, a 139 m interior
// path ~6 m), which is also the grain gate - at distance the march
// over-integrates the fine octaves instead of aliasing them (the r5
// static cannot happen).
vec4 vmarchseg(vec3 ro, vec3 rd, vec2 seg, float ca, float sa,
		float T_in, float L_in, float Lo_in) {
	float t0 = seg.x;
	float t1 = seg.y;
	float T = T_in;
	float L = L_in;
	float Lo = Lo_in;
	if (t1 - t0 < 1.0) {
		return vec4(T, L, Lo, 0.0);
	}
	float dl = (t1 - t0) / u_vol_steps;
	const int MAXV = 64;
	for (int i = 0; i < MAXV; i++) {
		if (float(i) >= u_vol_steps) {
			break;
		}
		float t = t0 + (float(i) + 0.5) * dl;
		vec3 p = ro + rd * t;
		vec3 q = vrot(p, ca, sa);
		float d = vdens(q);
		if (d > 0.015) {
			// Self-shadow: march a short ray TOWARD THE SUN through the
			// coarse field (the one thing a patterned surface cannot do
			// - a top sample's march exits the cloud, an underside
			// sample's stays inside it). Early exit once the optical
			// depth is saturated (exp(-3*..) ~ 0.03 is fully shadowed).
			float s = 0.0;
			float dl_l = 80.0;
			const int MAXL = 8;
			for (int k = 0; k < MAXL; k++) {
				if (float(k) >= u_vol_lsteps) {
					break;
				}
				vec3 pk = p + u_sun * ((float(k) + 0.5) * dl_l);
				s += vdens_coarse(vrot(pk, ca, sa));
				if (s > 3.0) {
					break;
				}
			}
			// The shadow optical depth uses the SAME extinction as the
			// view march (no deepening factor - the gate, not a 1.4x
			// fudge, confines the field the march sees).
			float sh = exp(-s * dl_l * u_vol_sigma);
			// cosSun = dot(sun, view direction): < 0 when the sun is on
			// the CAMERA side (it lights the camera-facing boundary),
			// > 0 when it is in front (backlit silhouette).
			float cosSun = clamp(dot(u_sun, rd), -1.0, 1.0);
			// Dark edge (the HZD powder role, the cheap 1-tap form): how
			// fast the density drops TOWARD THE CAMERA. A camera-facing
			// boundary is dark UNLESS the sun is on the camera side of
			// it (lit face - the -cosSun term suppresses the darkening
			// exactly when the visible face is the lit one); backlit
			// silhouettes keep the dark rim (the powder read).
			float dn = vdens_coarse(vrot(p - rd * (dl * 0.6), ca, sa));
			float edge = clamp(d - dn, 0.0, 1.0);
			float darkEdge = 1.0 - u_vol_edge * smoothstep(0.08, 0.4, edge)
				* (1.0 - 0.85 * smoothstep(-0.3, 0.7, -cosSun));
			// Phase: the scattering angle for sun->sample->camera is
			// between the direction TOWARD THE SUN and TOWARD THE
			// CAMERA = dot(u_sun, -rd) = -cosSun (the in-scatter
			// forward peak is a sunlit face seen from the sun side);
			// the out-scatter (camera-side sky fill) is the mirror
			// (+cosSun). Both are normalised by the HG peak vhg(1) so
			// the 2.5/0.30 albedo gains stay on the <= 1 integral
			// scale (the raw peak is ~13 at g=0.65 - unnormalised it
			// would saturate every lit sample to white and erase the
			// core/underside gradient).
			float ds = d * dl * u_vol_sigma;
			float hp = vhg(1.0);
			L += T * (vhg(-cosSun) / hp) * sh * darkEdge * ds;
			Lo += T * (vhg(cosSun) / hp) * ds;
		}
		T *= exp(-d * dl * u_vol_sigma);
		if (T < 0.004) {
			break;  // fully opaque: no sample behind can contribute
		}
	}
	return vec4(T, L, Lo, 0.0);
}

void fragment() {
	// AC-0405: the raymarched volume (Settings "cloud_volume"). The
	// short-circuit is before any volume work: u_vol < 0.5 falls through
	// to the three-shell path below, byte-identical to AC-0401. The
	// entry sits here (not in a helper) because the dummy parser
	// resolves the fragment builtins and `discard` in fragment() only.
	if (u_vol > 0.5) {
		vec3 ro = CAMERA_POSITION_WORLD;
		vec3 rd = normalize(v_wp - ro);
		vec3 w = ro - u_center;
		float rc = length(w);
		// One hemisphere only: outside the outer sphere the front face,
		// inside it the NEAR face - so each pixel is marched exactly
		// once and the same volume is never alpha-blended twice.
		vec3 Vv = normalize(ro - v_wp);
		float ndvv = dot(normalize(v_wp - u_center), Vv);
		if (rc > u_vol_rmax) {
			if (ndvv < 0.0) {
				discard;
			}
		} else {
			if (ndvv > 0.0) {
				discard;
			}
		}
		float ang = u_drift * u_cloud_time;
		float ca = cos(ang);
		float sa = sin(ang);
		vec3 acc = vec3(1.0, 0.0, 0.0);  // (T, L, Lo)
		vec2 sg1 = vseg1(w, rd, rc);
		acc = vmarchseg(ro, rd, sg1, ca, sa, acc.x, acc.y, acc.z).xyz;
		if (acc.x > 0.004) {
			vec2 sg2 = vseg2(w, rd, rc);
			acc = vmarchseg(ro, rd, sg2, ca, sa, acc.x, acc.y, acc.z).xyz;
		}
		float Av = 1.0 - acc.x;
		if (Av < 0.004) {
			discard;  // the annulus carries no density on this ray
		}
		// Lit tops -> near white, shaded undersides -> dark (the light
		// march IS the lambert: sh ~ 1 on sun-facing samples, ~ 0 on
		// undersides); u_day carries the day/night weight the deck path
		// uses (0.18 night floor), and the srgb pre-decode is the
		// unshaded-path convention (u_srgb_pre 1.0 on Forward+).
		ALBEDO = u_cloud_tint * u_day * clamp(2.5 * acc.y + 0.30 * acc.z, 0.0, 1.25);
		ALBEDO = mix(ALBEDO, pow(ALBEDO, vec3(2.2)), u_srgb_pre);
		ALPHA = Av;
	} else {
	// World-anchored direction from the planet centre (parallax + wrap).
	vec3 n = normalize(v_wp - u_center);
	// Wind drift: rotate the sampling direction about world Y. The old
	// 2-D wind was a translation; on the sphere the equivalent is a
	// rotation (east-west drift, polar stagnation for free).
	float ang = u_drift * u_cloud_time;
	float ca = cos(ang);
	float sa = sin(ang);
	vec3 dr = vec3(ca * n.x + sa * n.z, n.y, -sa * n.x + ca * n.z);
	// AC-0401: the deck character switch - the tunable constants of the
	// field and its windows, selected by u_deck. With u_deck < 0.5 every
	// value is exactly the pre-AC-0401 constant (the r9 path, unchanged);
	// with u_deck > 0.5 the field runs at 1/3 frequency (bigger masses),
	// the coverage window tightens (fewer clouds), the band troughs clear
	// (real gaps between the belts), and the edge windows soften.
	float sc3 = u_scale3;
	float wlo = 0.42, whi = 0.54;
	float cehi = 0.55;
	float bfloor = 0.75, blo = 0.18, bhi = 0.82;
	float elow = 0.05, ehi = 0.80;
	float vol = 0.0;
	if (u_deck > 0.5) {
		sc3 = u_scale3 * 0.33333;
		wlo = 0.46; whi = 0.56;
		cehi = 0.70;
		bfloor = 0.60; blo = 0.30; bhi = 0.90;
		elow = 0.00; ehi = 0.90;
		vol = 1.0;
	}
	vec3 q = dr * sc3 + u_phase;  // AC-0384 r9: the per-shell pattern offset
	// AC-0384 r5: distance LOD for the noise field (the round-4 "near-
	// disc static"). fbm() is 5 octaves (2.03x), so a band with
	// multiplier m has its finest octave at argument scale u_scale3*m*
	// 2.03^4; on this shell (radius R_sh) that is a world feature of
	// R_sh/(u_scale3*m*2.03^4), i.e. that/d_cam * u_cpxrad px on
	// screen. Below ~2.5 px the per-fragment white noise aliases into
	// the salt-and-pepper static (measured, 2600 m, same 400x400 box:
	// grain 23.2 clouds-ON vs 0.81 clouds-OFF - the static is this
	// field, not the body's texture). Each band is clamped so its
	// finest octave stays >= 2.5 px; at ground view the factors are
	// 1.0 (the finest octaves there are >= 1.8 px and low-contrast).
	float d_cam = max(length(CAMERA_POSITION_WORLD - v_wp), 1.0);
	float R_sh = length(v_wp - u_center);
	float px13 = R_sh * u_cpxrad / (sc3 * 1.3 * 16.974 * d_cam);
	float px22 = R_sh * u_cpxrad / (sc3 * 2.2 * 16.974 * d_cam);
	float px41 = R_sh * u_cpxrad / (sc3 * 4.1 * 16.974 * d_cam);
	float l13 = min(px13 / 2.5, 1.0);
	float l22 = min(px22 / 2.5, 1.0);
	float l41 = min(px41 / 2.5, 1.0);
	// Three frequencies, as in AC-0235 retest 5 - now in 3-D so the
	// pattern is continuous over the whole globe (no UV seam, no flat
	// projection).
	float base = fbm(q * 1.3 * l13);
	float mid = fbm(q * 2.2 * l22 + vec3(13.7, 7.3, 5.9));
	float fine = fbm(q * 4.1 * l41 + vec3(71.3, 33.9, 21.7));
	// AC-0385: coverage window 0.50-0.58 (was 0.62-0.88 - see header).
	// AC-0384 r8: re-placed to 0.46-0.54 - centred ON the fbm mean
	// (0.485, std 0.107, AC-0385's offline census), so roughly half the
	// field passes the mask instead of only its top ~30%. The 0.50/0.58
	// window left the mid-latitude belt (the whole of the inside-shell
	// descent view: the planet preset frame at 120 m spans 52.5-127.5
	// deg from the zenith) at 0.19% pattern at CLOUD_T0=411200 - the
	// player's reported "clouds below the terrain" (the visible sliver
	// was a band-phase at the horizon, the dense cap above the frame).
	// AC-0384 r9 (round 6): the lower bound moves to 0.42. r8b's window
	// (0.46) left the descent views (1600/700 m: the spawn-side cap the
	// tangent-limb frame sees) below the threshold at the reference
	// weather (CLOUD_T0=411200: 0.000% census - the coarse field there
	// sits ~0.45, one clear phase of the shared field). The r9 lower
	// bound sets the effective threshold (window lower bound + the
	// 0.05/0.80 contrast floor + the boost/cov chain) at ~0.464 on the
	// top shell, so every descent view carries structured cloud at every
	// observed weather instead of relying on a lucky phase; the per-shell
	// u_phase offsets above keep the three decks' patterns independent.
	// The 0.05 contrast floor still kills the thin haze below it (no
	// milk; the cores stay occluding through u_boost).
	// AC-0401: the four windows below are the u_deck parameters (wlo/
	// whi/cehi/bfloor/blo/bhi/elow/ehi) - with u_deck < 0.5 they hold the
	// exact pre-AC-0401 constants.
	float cl = smoothstep(wlo, whi, base);
	cl = smoothstep(0.0, cehi, cl) * cl;
	cl *= bfloor + (1.0 - bfloor) * (0.55 * base + 0.45 * mid);
	cl *= 0.85 + 0.15 * fine;
	// AC-0384 r6: broad warped latitude bands - large-scale weather
	// structure (the NMS deck is banded, not uniform). The band follows
	// the drift-rotated direction so it scrolls with the weather.
	// AC-0384 r8: 11 cycles -> 5 (broad belts: one thick band crosses
	// the descent frame instead of ~2 in/out phases) and the floor
	// 0.5 -> 0.75 (even the band troughs carry 75% of the field, so the
	// belt never reads as a clear stripe). Low-frequency only - the r5
	// grain gate (4.71/1.90 @ 2600 m) is the guard.
	float band = 0.5 + 0.5 * sin(dr.y * 5.0 + 2.2 * base);
	cl *= mix(bfloor, 1.0, smoothstep(blo, bhi, band));
	// AC-0384 r6: soft bimodal contrast - the haze reads as a thin veil
	// and the cores as opaque masses (wide window 0.05/0.80; the first
	// pass 0.16/0.58 steepened the edges and raised the orbit grain).
	cl = smoothstep(elow, ehi, cl);
	// Grazing fade: thin the mass where the shell is seen edge-on, so the
	// silhouette stays clean where the satellite body's own limb haze is
	// strongest (no double white rim at the limb from orbit). AC-0384 r6:
	// abs() - the same fade applies to the underside view from inside.
	vec3 V = normalize(CAMERA_POSITION_WORLD - v_wp);
	float ndv = dot(n, V);
	float graze = smoothstep(0.02, 0.18, abs(ndv));
	// AC-0384 r6: occluding cores - the dense cores clamp to full opacity
	// (u_boost 2.0), so the deck hides the sky and the terrain behind it.
	float a = clamp(cl * u_coverage * u_boost, 0.0, 1.0);
	// AC-0384 r6: fragment-stage cull emulation. cull_disabled is
	// required to see the shell from inside (the rasterizer cull with
	// cull_back discarded the whole underside), but with cull off the
	// far side of the shell would draw through the near side (the
	// transparent pass keeps no depth). Discard the back faces only
	// while the camera is OUTSIDE this shell: the orbit view is exactly
	// the r5 view, and the underside renders when the camera is inside.
	float cam_out = step(R_sh, length(CAMERA_POSITION_WORLD - u_center));
	if (cam_out > 0.5 && ndv < 0.0) {
		discard;
	}
	ALPHA = a * graze;
	// AC-0382 sun convention (the satellite body's exact uniform set):
	// u_sun is the direction TO the sun, the light travels along
	// DayNight.sun_direction. Noon (sun_l=1) is unchanged; the night
	// floor 0.18 matches the satellite's pre-AC-0382 night.
	float sun_l = clamp(dot(n, u_sun), 0.0, 1.0);
	float light = u_day - u_day_gain * (1.0 - sun_l);
	// AC-0384 r6: darker undersides - the optically thicker the patch
	// (the final alpha a), the less light leaks through it.
	// AC-0401: the volumetric read (vol = 1.0 when u_deck is ON, else 0.0
	// and both terms are exactly 1.0 / u_under - the pre-AC-0401 ALBEDO):
	// puff brightness off the mid field lifts the lumps' tops and shadows
	// their shoulders (lit-from-above mass), and the thickness darkening
	// deepens (u_under 0.70 -> 0.58 at full opacity) so the cores read as
	// deep, light-scattering volume instead of a flat membrane.
	float puff = 1.0 + 0.14 * vol * (smoothstep(0.35, 0.65, mid) - 0.5);
	float under = mix(u_under, 0.58, vol);
	ALBEDO = u_cloud_tint * light * mix(1.0, under, a) * puff;
	ALBEDO = mix(ALBEDO, pow(ALBEDO, vec3(2.2)), u_srgb_pre); // AC-0242
	}
}
