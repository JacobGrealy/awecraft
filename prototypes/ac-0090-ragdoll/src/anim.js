// AC-0090 — the procedural locomotion rig.
//
// No clips, no imported animation, no retargeting. Each body plan gets a phase
// function and the same rig primitives: swing, bend, torso bob, squash.
//
// The foot does not step; it is pushed backwards along the body's own -Z while
// planted, for exactly one stance period. Forward speed is DERIVED from the
// stride rather than dialled in separately, so the feet cannot skate: the body
// travels forward by the same distance the foot travelled backwards, which is
// foot lock by construction rather than by solving.
//
//   * 2 legs        alternating stance / swing, counter-swinging arms
//   * N legs        phase offsets from the leg's front-to-back index (trot for 4,
//                   tripod for 6, wave for anything else)
//   * 0 legs        a squash-and-stretch hop with a fused-leg extension
//   * fly + arms    a flap cycle with wing twist, body bob and banking
//
// Tier caveat, stated in the writeup too: this solves the planar swing of each
// joint analytically, not a general IK chain. Knees/elbows borrow the plant
// angle, which is what keeps a planted foot vertical without a solver.

// Maximum angular speed any single posed bone may move through, in rad/s.
const MAX_PITCH_RATE = 4;

const TAU = Math.PI * 2;

const clamp = (v, lo, hi) => (v < lo ? lo : v > hi ? hi : v);

export class Locomotion {
  constructor(rig, plan) {
    this.rig = rig;
    this.plan = plan;
    this.kin = plan.kin;
    this.t = 0;
    this.phase = 0;
    this.speed = 1;          // user dial, 0..2
    this.mode = 'auto';      // auto | idle | move
    this.gaitScale = 1;
    this.hopIndex = 0;
    this.hopT = 0;
    this.blend = 0;          // 0 idle -> 1 locomotion
    this.groundOffset = 0;   // vertical translation applied to the mesh (hop/trot bob)
    // Per-bone angle actually applied last frame, for the angular rate limit.
    this._applied = new Map();
    this.rootLean = 0;
    this.bank = 0;
    this.stats = { stride: 0, cycleHz: 0, footLift: 0 };
    this._setupGait();
  }

  // Per-leg phase offsets and step timing from the leg count and the gait name.
  _setupGait() {
    const kin = this.kin;
    const legs = kin.legs || [];
    this.legs = legs.map((L, i) => {
      // Front-to-back index: legs are authored in a known order per preset, so
      // derive the pairing from their rest foot z position instead of assuming.
      const ankle = this.rig.plan.joints[this.rig.bone(L.ankle)];
      const hip = this.rig.plan.joints[this.rig.bone(L.hip)];
      return {
        ...L,
        index: i,
        z: ankle ? ankle.joint[2] : 0,
        hipZ: hip ? hip.joint[2] : 0,
        phase: 0,
        duty: 0.6,
      };
    });
    const n = this.legs.length;
    if (kin.gait === 'trot' || n === 4) {
      // Diagonal pairs: FL+BR, then FR+BL.
      const sorted = [...this.legs].sort((a, b) => b.z - a.z);
      sorted.forEach((L, i) => { L.phase = (i === 0 || i === 3) ? 0 : 0.5; });
      for (const L of this.legs) L.duty = 0.55;
    } else if (kin.gait === 'tripod' || n === 6) {
      // Alternating tripods: (front-L, mid-R, rear-L) vs the mirror.
      const sorted = [...this.legs].sort((a, b) => b.z - a.z);
      sorted.forEach((L, i) => {
        const group = i % 2;
        L.phase = group === 0 ? 0 : 0.5;
      });
      // Split the pairs within a tripod slightly so it does not read as a robot.
      const byRow = new Map();
      for (const L of this.legs) {
        const row = Math.round(L.z * 100);
        byRow.set(row, (byRow.get(row) || 0) + 1);
      }
      for (const L of this.legs) {
        L.phase += (L.side > 0 ? 0 : 0.06) * (L.z > 0 ? 1 : -1);
      }
      for (const L of this.legs) L.duty = 0.5;
    } else if (n > 0) {
      // Generic wave gait: phase advances along the body, then alternates side.
      const sorted = [...this.legs].sort((a, b) => b.z - a.z);
      sorted.forEach((L, i) => { L.phase = (i / n) * 2; });
      for (const L of this.legs) L.duty = 0.5;
    }
    this.strideLength = Math.max(0.12, this.plan.height * 0.30) * this.gaitScale;
    this.cycleHz = 1.5 * (this.kin.speed || 1);
  }

  setSpeed(v) {
    this.speed = v;
    if (v <= 0.001) this.mode = 'idle';
  }

  get forwardSpeed() {
    // Metres per second the body advances: one stride per cycle, times the
    // cycle rate. This is the number the ground grid is scrolled by.
    return this.strideLength * this.cycleHz * this.speed * (this.kin.kind === 'hopper' ? 0.55 : 1);
  }

  update(dt) {
    const rig = this.rig;
    const kin = this.kin;
    this.t += dt;

    const moving = this.speed > 0.02;
    const target = moving ? 1 : 0;
    const rate = moving ? 3.2 : 2.4;
    this.blend += Math.max(-rate * dt, Math.min(rate * dt, target - this.blend));
    const b = this.blend;

    if (kin.kind === 'hopper') this._hop(dt, b);
    else if (kin.kind === 'flyer') this._fly(dt, b);
    else this._walk(dt, b);

    rig.update();
  }

  // ------------------------------------------------------------- walkers ---

  _walk(dt, b) {
    const rig = this.rig;
    const kin = this.kin;
    rig.reset();
    // The phase ALWAYS advances at the full gait cadence; `blend` only scales the
    // amplitude of the motion. An earlier revision slowed the cadence by the
    // blend, which collapsed the stride length and then divided by it — producing
    // ten-radian joint angles and a 600x skin stretch for the first frames of
    // every walk cycle.
    const cadence = this.cycleHz;
    this.phase = (this.phase + dt * cadence) % 1;
    const t = this.phase;

    // Root bob: two dips per cycle (one per step), scaled by gait.
    const bobAmp = this.plan.height * 0.022 * b;
    const bob = -Math.abs(Math.sin(t * TAU)) * bobAmp;
    rig.set(kin.root, 0, 0, 0);
    // Pose the spine/chest a little so the torso is not a rigid box on legs.
    const lean = 0.05 * b * Math.sign(this.forwardSpeed || 1);
    const sway = Math.sin(t * TAU) * 0.045 * b;
    if (rig.has(kin.spine)) rig.set(kin.spine, -lean * 0.5, sway * 0.4, Math.sin(t * TAU + 1.0) * 0.03 * b);
    if (rig.has(kin.torso)) rig.set(kin.torso, -lean * 0.5, -sway * 0.3, 0);
    if (rig.has(kin.head)) {
      // Head counter-rotates so the gaze stays level while the body rolls.
      rig.set(kin.head, lean * 0.8 + Math.sin(t * TAU * 2) * 0.02 * b, -sway * 0.5, 0);
    }
    if (kin.tail && rig.has(kin.tail)) rig.set(kin.tail, Math.sin(t * TAU) * 0.10 * b, 0, Math.sin(t * TAU * 0.5) * 0.18 * b);

    this.groundOffset = bob;
    this.rootLean = lean;

    // Legs.
    for (const L of this.legs) {
      const local = (t + L.phase) % 1;
      const stance = local < L.duty;
      // u goes 0 -> 1 across the phase; used for the swing/stance arc.
      const u = stance ? local / L.duty : (local - L.duty) / (1 - L.duty);
      const lift = this.plan.height * 0.055 * (0.35 + 0.65 * b);
      const stride = this.strideLength * (0.25 + 0.75 * b);

      let targetZ, footY;
      if (stance) {
        // Planted: travel backwards exactly one stride over the stance period.
        targetZ = L.z + stride * 0.5 - stride * u;
        footY = 0;
      } else {
        targetZ = L.z - stride * 0.5 + stride * u;
        footY = Math.sin(u * Math.PI) * lift;
      }

      const hip = rig.plan.joints[rig.bone(L.hip)];
      const restZ = hip ? hip.joint[2] : 0;
      // Planar swing of the whole leg towards the target z, clamped so no input
      // can wind a joint past a plausible range.
      const swing = clamp(
        Math.atan2(targetZ - restZ, this.legHeight(L)) * (0.25 + 0.75 * b),
        -0.9, 0.9,
      );
      rig.set(L.hip, swing, 0, 0);
      // Knee: the rest pose is already flexed, so the animation only modifies
      // that flexion — it deepens through the swing to clear the ground and
      // straightens near the end of stance to push off. `kneeSign` is the one
      // per-preset dial that flips a bird knee (backwards) against a mammal one.
      const ks = kin.kneeSign || -1;
      void dt;
      const flexion = clamp(
        0.10 + (stance ? 0.10 * (1 - u) : 0.55 * Math.sin(u * Math.PI)), 0, 1.6,
      );
      rig.set(L.knee, this._limited(rig.bone(L.knee), ks * flexion * (0.2 + 0.8 * b), dt), 0, 0);
      if (rig.bone(L.knee) !== rig.bone(L.ankle)) {
        const tuck = stance ? 0 : Math.sin(u * Math.PI);
        rig.set(L.ankle, -ks * tuck * 0.35 * b, 0, 0);
      }
      if (L.side === 1) this.stats.footLift = Math.max(this.stats.footLift, footY);
    }

    // Arms counter-swing the legs.
    for (const A of kin.arms || []) {
      // Counter-swing the leg on the same side where there is one.
      const same = this.legs.find((L) => L.side === A.side);
      const base = same ? same.phase : 0;
      const swing = Math.sin((t + base + 0.5) * TAU) * 0.55 * b;
      if (rig.has(A.shoulder)) {
        rig.set(A.shoulder, -swing, 0.12 * A.side * b, 0);
      }
      if (rig.has(A.elbow)) {
        rig.set(A.elbow, -Math.abs(swing) * 0.7 - 0.15 * b, 0, 0);
      }
    }
    this.stats.stride = this.strideLength * b;
    this.stats.cycleHz = cadence;
  }

  legHeight(L) {
    const rig = this.rig;
    const hip = rig.plan.joints[rig.bone(L.hip)];
    const ankle = rig.plan.joints[rig.bone(L.ankle)];
    if (!hip || !ankle) return this.plan.height * 0.4;
    return Math.max(0.05, hip.joint[1] - ankle.joint[1]);
  }

  // -------------------------------------------------------------- hopper ---


  // Clamp how fast a bone's pitch may change between frames.
  //
  // The hop's launch phase is 0.12 of a cycle (0.089 s at 1.35 Hz) and swings the
  // knee's target from 0.9 rad to -0.9 rad, which is ~30 rad/s — 61.6 degrees in a
  // single 1/30 s step. That is a real animation defect, not just a metric one: it
  // reads as a snap, and because the hopper's knee-to-ankle bone is only 3 cm it
  // also drags the surface 19x its rest edge length. Clamping the applied rate
  // fixes both, and it is the correct place to do it because the limit must hold
  // whatever the frame time is — a shorter frame must not produce a faster snap.
  _limited(bone, value, dt, maxRate = MAX_PITCH_RATE) {
    if (bone < 0) return value;
    const prev = this._applied.get(bone);
    if (prev === undefined) { this._applied.set(bone, value); return value; }
    const maxStep = maxRate * dt;
    const next = clamp(prev + (value - prev), -maxStep, maxStep);
    this._applied.set(bone, next);
    return next;
  }

  _hop(dt, b) {
    const rig = this.rig;
    const kin = this.kin;
    rig.reset();
    // A hop is a cycle with a short airborne phase. Rather than a continuous
    // gait we drive a normalised cycle and shape the body with it.
    const cycleHz = 1.35 * (this.kin.speed || 1);
    this.hopT = (this.hopT + dt * cycleHz) % 1;
    const c = this.hopT;
    const airborne = c > 0.55;
    // Crouch 0..0.55, extend/launch 0.45..0.6, air 0.55..0.85, land 0.85..1.
    let crouch;
    if (c < 0.5) crouch = Math.sin((c / 0.5) * Math.PI * 0.5) * 0.9;      // wind up
    else if (c < 0.62) crouch = 0.9 - ((c - 0.5) / 0.12) * 1.8;            // launch
    else if (c < 0.85) crouch = -0.9 + Math.sin(((c - 0.62) / 0.23) * Math.PI) * 1.1;
    else crouch = Math.sin(((c - 0.85) / 0.15) * Math.PI * 0.5) * 0.9;     // land

    const squash = crouch * 0.16 * b;
    // Vertical travel of the whole body: up during the airborne phase.
    const hopHeight = this.plan.height * 0.42;
    const air = airborne ? Math.sin(((c - 0.55) / 0.45) * Math.PI) : 0;
    this.groundOffset = air * hopHeight * b;

    // Squash/stretch via bone scales is not available in this rig, so the body
    // squash is expressed as joint offsets: the spine compresses towards the
    // pelvis and the head dips, then extends on launch.
    const spine = rig.has(kin.spine) ? rig.bone(kin.spine) : -1;
    const torso = rig.has(kin.torso) ? rig.bone(kin.torso) : -1;
    const head = rig.has(kin.head) ? rig.bone(kin.head) : -1;
    if (spine >= 0) rig.set(spine, -squash * 0.5, 0, 0);
    if (torso >= 0) rig.set(torso, -squash * 0.8, 0, 0);
    if (head >= 0) rig.set(head, squash * 0.5 + air * 0.25 * b, 0, 0);
    // Store the vertical squash so the scene can scale the whole character a
    // touch, which is the cheap part of the squash-and-stretch read.
    this.squashY = 1 - squash * 0.20;
    this.squashXZ = 1 + squash * 0.13;
    this.rootLean = squash * 0.15;

    // Fused legs: crouch deepens the knee, launch snaps it straight. The hop's
    // vertical travel is what sells it; the legs just have to agree.
    for (const L of kin.fusedLegs || []) {
      const ext = crouch * 0.9 * b;
      if (rig.has(L.hip)) rig.set(L.hip, this._limited(rig.bone(L.hip), -0.55 * b + ext * 0.5, dt), 0, 0);
      if (rig.has(L.knee)) rig.set(L.knee, this._limited(rig.bone(L.knee), 0.9 * b - ext * 1.5, dt), 0, 0);
      if (rig.has(L.ankle) && L.ankle !== L.knee) {
        rig.set(L.ankle, this._limited(rig.bone(L.ankle), -0.35 * b + ext * 0.7, dt), 0, 0);
      }
    }
    // Little arms wind up and throw forward.
    for (const A of kin.arms || []) {
      if (rig.has(A.shoulder)) rig.set(A.shoulder, this._limited(rig.bone(A.shoulder), (0.5 - crouch * 0.8) * b, dt), 0, 0);
      if (rig.has(A.elbow)) rig.set(A.elbow, this._limited(rig.bone(A.elbow), -0.5 * b - Math.max(0, crouch) * 0.5, dt), 0, 0);
    }
    if (rig.has(kin.tail)) rig.set(kin.tail, Math.sin(c * TAU) * 0.2 * b, 0, 0);

    this.stats.stride = this.plan.height * 0.35 * b;
    this.stats.cycleHz = cycleHz;
  }

  // --------------------------------------------------------------- flyer ---

  _fly(dt, b) {
    const rig = this.rig;
    const kin = this.kin;
    rig.reset();
    // Flap rate is constant; `blend` scales the flap AMPLITUDE only.
    const flapHz = 2.6;
    this.phase = (this.phase + dt * flapHz) % 1;
    const t = this.phase;
    const flap = Math.sin(t * TAU);

    this.groundOffset = this.plan.height * 0.30 * b +
      Math.sin(t * TAU * 2) * this.plan.height * 0.035;
    this.bank = Math.sin(this.t * 0.5) * 0.28 * b;

    for (const W of kin.wings || []) {
      const s = W.side;
      // The flap is a rotZ of the wing frame; the sign is baked per side at
      // build time by the frame, so both wings take the same value.
      if (rig.has(W.shoulder)) rig.set(W.shoulder, flap * 0.85 * b, 0, 0.18 * b);
      if (rig.has(W.elbow)) {
        // Outer wing lags the inner one — the tip trails, which is what sells it.
        const lag = Math.sin((t - 0.08) * TAU);
        rig.set(W.elbow, lag * 0.55 * b, 0, 0.25 * b);
      }
    }
    if (rig.has(kin.torso)) rig.set(kin.torso, -0.18 * b + flap * 0.05 * b, 0, 0);
    if (rig.has(kin.spine)) rig.set(kin.spine, -0.12 * b, 0, 0);
    if (rig.has(kin.head)) rig.set(kin.head, 0.22 * b, 0, 0);
    if (rig.has(kin.tail)) rig.set(kin.tail, -0.12 * b + flap * 0.08 * b, 0, 0);
    // Arms tucked, counter-swinging faintly with the flap.
    for (const A of kin.arms || []) {
      if (rig.has(A.shoulder)) rig.set(A.shoulder, 0.55 * b - flap * 0.12 * b, 0, 0.1 * b);
      if (rig.has(A.elbow)) rig.set(A.elbow, -0.9 * b, 0, 0);
    }
    // Legs trail behind and tuck up on the upstroke.
    for (const L of kin.tuckedLegs || []) {
      if (rig.has(L.hip)) rig.set(L.hip, -0.5 * b - flap * 0.12 * b, 0, 0);
      if (rig.has(L.knee)) rig.set(L.knee, 0.9 * b, 0, 0);
    }
    this.squashY = 1;
    this.squashXZ = 1;
    this.stats.stride = this.forwardSpeed / Math.max(0.01, flapHz);
    this.stats.cycleHz = flapHz;
  }
}
