// AC-0090 — the body plans.
//
// Each preset is a function from a seed to a finished plan. Nothing here is
// hand-modelled: the generator turns the joint graph plus a small number of
// numeric dials into geometry, and a different seed moves the dials.
//
// Every plan declares its locomotion wiring in `kin` so the animation rig never
// special-cases a creature by name.

import { makePlan, addJoint, tube, lump, part, finalize, recenter } from './bodyplan.js';

// ------------------------------------------------------------------ tint ---

export const PALETTES = {
  mint: { a: '#7fd6a6', b: '#3f8f66', accent: '#ffe08a', outline: '#16241d' },
  coral: { a: '#f2795e', b: '#8c2f2a', accent: '#ffd9a0', outline: '#2a1410' },
  violet: { a: '#9a8cf0', b: '#4a3fa8', accent: '#bfe9ff', outline: '#171334' },
  sand: { a: '#e2c07a', b: '#a3762f', accent: '#fff3cf', outline: '#2c2110' },
  sky: { a: '#7fc4ee', b: '#31618f', accent: '#ffd9ec', outline: '#101f2c' },
  ash: { a: '#9aa3ad', b: '#4c545e', accent: '#ffb27a', outline: '#14171b' },
};

function hexToRgb(hex) {
  const h = hex.replace('#', '');
  return [
    parseInt(h.slice(0, 2), 16) / 255,
    parseInt(h.slice(2, 4), 16) / 255,
    parseInt(h.slice(4, 6), 16) / 255,
  ];
}

export function tints(name) {
  const p = PALETTES[name] || PALETTES.mint;
  return { a: hexToRgb(p.a), b: hexToRgb(p.b), accent: hexToRgb(p.accent), outline: hexToRgb(p.outline) };
}

// --------------------------------------------------------------- helpers ---

// A chain of joints and the tapered tube (plus joint balls) that skins it.
// `sides` mirrors the chain across x = 0, which is how every limb is built.
function chain(plan, partName, names, pts, radii, opts = {}) {
  if (opts === null || Array.isArray(opts) || typeof opts !== 'object') {
    throw new Error(`chain(${names.join('/')}): 6th argument must be an options object`);
  }
  if (names.length !== pts.length || names.length !== radii.length) {
    throw new Error(`chain(${names.join('/')}): names/points/radii length mismatch`);
  }
  const sides = opts.sides || [1];
  const made = [];
  for (const side of sides) {
    const suffix = sides.length > 1 ? (side > 0 ? '_l' : '_r') : '';
    const chainNames = [];
    for (let i = 0; i < names.length; i++) {
      const jn = names[i] + suffix;
      if (opts.existing && plan.bones[jn]) {
        // Joint already declared by the preset: reuse it, just skin the tube to it.
        chainNames.push(jn);
        continue;
      }
      const parent = i === 0 ? opts.parent : names[i - 1] + suffix;
      addJoint(plan, jn, [pts[i][0] * side, pts[i][1], pts[i][2]], parent, { radius: radii[i] });
      chainNames.push(jn);
    }
    tube(plan, partName, chainNames.map((n) => plan.bones[n].joint), radii, {
      bones: chainNames,
      ringParts: opts.ringParts ?? 12,
      ringsPerSegment: opts.ringsPerSegment ?? 7,
      blend: opts.blend ?? 0.55,
      material: opts.material || 0,
      capsuleCap: opts.capsuleCap !== false,
    });
    if (opts.jointBalls !== false) {
      for (let i = 0; i < names.length; i++) {
        const jn = chainNames[i];
        const j = plan.bones[jn];
        const r = (opts.ballRadii ? opts.ballRadii[i] : radii[i]) * 1.02;
        lump(plan, partName, j.joint, [r, r, r], { bone: jn, subdiv: 1, material: opts.material || 0 });
      }
    }
    made.push(chainNames);
  }
  return made;
}

// Every preset's torso is a stack of overlapping blobs at pelvis/spine/chest/head,
// which leaves the NECK joint with no geometry of its own: the bone exists, is
// animated (the head counter-rotates through it) and skins nothing. A small sphere
// at the neck joint fixes that and keeps the chest-to-head transition continuous
// when the head turns. Sized from the joint's declared radius so it stays inside
// the silhouette the neighbouring blobs already establish.
function neckBall(plan, partName = 'body') {
  const j = plan.bones.neck;
  if (!j) return;
  const r = j.radius || 0.05;
  blob(plan, partName, j.joint, [r * 1.05, r * 1.05, r * 1.05], 'neck', { round: 0.75 });
}

// Global bulk applied to every lump radius.
//
// This exists because the per-preset radii are authored as *base* sizes that the
// limb attachment points are laid out against: the biped's shoulder sits at
// x = 0.20 while its chest blob has radius 0.20, so the arm only clears the torso
// while the bulk stays near 1. Raising it to 1.35 swallowed the arms entirely
// (verified by eye: the creature rendered as a smooth lump with no limbs), and
// 1.9 did it for every preset. If a creature needs more mass, move the limb
// attachment points out rather than inflating the torso over them.
const BLOB_BULK = 1.0;

function blob(plan, partName, centre, radii, bone, opts = {}) {
  return lump(plan, partName, centre, radii.map((r) => r * BLOB_BULK), {
    bone,
    subdiv: opts.subdiv ?? 2,
    round: opts.round ?? 1,
    material: opts.material || 0,
  });
}

// --------------------------------------------------------------- presets ---

function biped(seed) {
  const plan = makePlan(seed);
  plan.name = 'biped';
  plan.title = 'Biped — 2 legs, arms';
  plan.palette = 'mint';
  part(plan, 'body', { kind: 'body' });
  part(plan, 'limbs', { kind: 'limb' });
  part(plan, 'detail', { kind: 'detail' });

  addJoint(plan, 'pelvis', [0, 0.88, 0], null, { radius: 0.13 });
  addJoint(plan, 'spine', [0, 1.05, 0.005], 'pelvis', { radius: 0.12 });
  addJoint(plan, 'chest', [0, 1.26, 0.005], 'spine', { radius: 0.15 });
  addJoint(plan, 'neck', [0, 1.45, 0], 'chest', { radius: 0.055 });
  addJoint(plan, 'head', [0, 1.58, 0.01], 'neck', { radius: 0.15 });

  // Torso: three overlapping rounded volumes, low `round` so it reads as a
  // chunky primitive body rather than a smooth human.
  blob(plan, 'body', [0, 0.86, 0], [0.175, 0.155, 0.125], 'pelvis', { round: 0.5 });
  blob(plan, 'body', [0, 1.05, 0.005], [0.16, 0.14, 0.115], 'spine', { round: 0.5 });
  blob(plan, 'body', [0, 1.28, 0.005], [0.20, 0.16, 0.13], 'chest', { round: 0.5 });
  blob(plan, 'body', [0, 1.59, 0.005], [0.145, 0.16, 0.145], 'head', { round: 0.35 });
  blob(plan, 'detail', [0, 1.545, 0.135], [0.085, 0.06, 0.06], 'head', { round: 0.6 });
  blob(plan, 'detail', [-0.062, 1.625, 0.115], [0.03, 0.032, 0.022], 'head');
  blob(plan, 'detail', [0.062, 1.625, 0.115], [0.03, 0.032, 0.022], 'head');

  // Arms: shoulder -> elbow -> wrist, one tube across both joints.
  chain(plan, 'limbs', ['shoulder', 'elbow', 'wrist'],
    [[0.20, 1.375, 0], [0.265, 1.12, 0], [0.245, 0.885, 0.01]],
    [0.072, 0.058, 0.05],
    { sides: [1, -1], parent: 'chest', ringParts: 10, blend: 0.6 });
  for (const s of [1, -1]) {
    const sfx = s > 0 ? '_l' : '_r';
    blob(plan, 'limbs', [0.243 * s, 0.845, 0.012], [0.056, 0.05, 0.062], 'wrist' + sfx, { round: 0.6 });
  }

  // Legs: hip -> knee -> ankle, with a foot block whose flat top sinks into the
  // ankle ball so the joint still reads as one piece when the knee bends.
  chain(plan, 'limbs', ['hip', 'knee', 'ankle'],
    [[0.095, 0.84, 0], [0.105, 0.47, 0.005], [0.10, 0.115, 0]],
    [0.092, 0.072, 0.056],
    { sides: [1, -1], parent: 'pelvis', ringParts: 10, blend: 0.6 });
  for (const s of [1, -1]) {
    const sfx = s > 0 ? '_l' : '_r';
    blob(plan, 'limbs', [0.103 * s, 0.048, 0.035], [0.078, 0.05, 0.125], 'ankle' + sfx, { round: 0.55 });
  }

  plan.kin = {
    kind: 'biped',
    spine: 'spine',
    torso: 'chest',
    root: 'pelvis',
    head: 'head',
    legs: [leg('hip_l', 'knee_l', 'ankle_l'), leg('hip_r', 'knee_r', 'ankle_r')],
    arms: [arm('shoulder_l', 'elbow_l'), arm('shoulder_r', 'elbow_r')],
    speed: 1.0,
    gait: 'walk',
    kneeSign: -1,
  };
  plan.meta = { height: 1.74 };
  return finalize(recenter(plan));
}

const leg = (hip, knee, ankle) => ({ hip, knee, ankle, side: hip.endsWith('_l') ? 1 : -1 });
const arm = (shoulder, elbow) => ({ shoulder, elbow, side: shoulder.endsWith('_l') ? 1 : -1 });

function quadruped(seed) {
  const plan = makePlan(seed);
  plan.name = 'quadruped';
  plan.title = 'Quadruped — 4 legs, trot';
  plan.palette = 'coral';
  part(plan, 'body', { kind: 'body' });
  part(plan, 'limbs', { kind: 'limb' });
  part(plan, 'detail', { kind: 'detail' });

  addJoint(plan, 'pelvis', [0, 0.62, -0.30], null, { radius: 0.13 });
  addJoint(plan, 'spine', [0, 0.645, -0.05], 'pelvis', { radius: 0.13 });
  addJoint(plan, 'chest', [0, 0.66, 0.24], 'spine', { radius: 0.15 });
  addJoint(plan, 'neck', [0, 0.72, 0.44], 'chest', { radius: 0.07 });
  addJoint(plan, 'head', [0, 0.76, 0.60], 'neck', { radius: 0.13 });
  addJoint(plan, 'tail', [0, 0.63, -0.42], 'pelvis', { radius: 0.05 });
  addJoint(plan, 'tailTip', [0, 0.66, -0.62], 'tail', { radius: 0.03 });

  blob(plan, 'body', [0, 0.62, -0.30], [0.155, 0.15, 0.16], 'pelvis', { round: 0.55 });
  blob(plan, 'body', [0, 0.645, -0.05], [0.15, 0.155, 0.22], 'spine', { round: 0.55 });
  blob(plan, 'body', [0, 0.665, 0.24], [0.165, 0.16, 0.17], 'chest', { round: 0.55 });
  blob(plan, 'body', [0, 0.755, 0.615], [0.115, 0.105, 0.14], 'head', { round: 0.45 });
  blob(plan, 'detail', [0, 0.71, 0.735], [0.062, 0.05, 0.055], 'head', { round: 0.6 });
  blob(plan, 'detail', [-0.055, 0.815, 0.60], [0.024, 0.026, 0.02], 'head');
  blob(plan, 'detail', [0.055, 0.815, 0.60], [0.024, 0.026, 0.02], 'head');
  chain(plan, 'detail', ['tail', 'tailTip'],
    [[0, 0.63, -0.42], [0, 0.665, -0.65]], [0.042, 0.028],
    { parent: 'pelvis', ringParts: 8, ringsPerSegment: 5, existing: true, jointBalls: false });

  // Front pair off the chest, rear pair off the pelvis.
  chain(plan, 'limbs', ['shoulderF', 'kneeF', 'ankleF'],
    [[0.125, 0.60, 0.22], [0.135, 0.34, 0.235], [0.13, 0.09, 0.215]],
    [0.078, 0.058, 0.045],
    { sides: [1, -1], parent: 'chest', ringParts: 9, blend: 0.6 });
  chain(plan, 'limbs', ['hipB', 'kneeB', 'ankleB'],
    [[0.125, 0.58, -0.30], [0.14, 0.33, -0.36], [0.13, 0.09, -0.29]],
    [0.088, 0.062, 0.045],
    { sides: [1, -1], parent: 'pelvis', ringParts: 9, blend: 0.6 });
  for (const s of [1, -1]) {
    const sfx = s > 0 ? '_l' : '_r';
    blob(plan, 'limbs', [0.13 * s, 0.042, 0.235], [0.062, 0.042, 0.085], 'ankleF' + sfx, { round: 0.6 });
    blob(plan, 'limbs', [0.13 * s, 0.042, -0.30], [0.066, 0.042, 0.09], 'ankleB' + sfx, { round: 0.6 });
  }

  const mk = (h, k, a) => leg(h, k, a);
  plan.kin = {
    kind: 'quadruped',
    spine: 'spine',
    torso: 'chest',
    root: 'pelvis',
    head: 'head',
    tail: 'tail',
    legs: [mk('shoulderF_l', 'kneeF_l', 'ankleF_l'), mk('hipB_l', 'kneeB_l', 'ankleB_l'),
      mk('shoulderF_r', 'kneeF_r', 'ankleF_r'), mk('hipB_r', 'kneeB_r', 'ankleB_r')],
    arms: [],
    speed: 1.15,
    gait: 'trot',
    kneeSign: -1,
  };
  plan.meta = { height: 0.95 };
  return finalize(recenter(plan));
}

function hexapod(seed) {
  const plan = makePlan(seed);
  plan.name = 'hexapod';   // the preset KEY stays stable; the count does not
  plan.palette = 'violet';
  part(plan, 'body', { kind: 'body' });
  part(plan, 'limbs', { kind: 'limb' });
  part(plan, 'detail', { kind: 'detail' });

  addJoint(plan, 'pelvis', [0, 0.30, -0.22], null, { radius: 0.09 });
  addJoint(plan, 'spine', [0, 0.315, 0], 'pelvis', { radius: 0.09 });
  addJoint(plan, 'chest', [0, 0.30, 0.22], 'spine', { radius: 0.10 });
  addJoint(plan, 'neck', [0, 0.28, 0.36], 'chest', { radius: 0.045 });
  addJoint(plan, 'head', [0, 0.29, 0.46], 'neck', { radius: 0.075 });

  blob(plan, 'body', [0, 0.30, -0.22], [0.115, 0.095, 0.13], 'pelvis', { round: 0.6 });
  blob(plan, 'body', [0, 0.315, 0], [0.11, 0.10, 0.14], 'spine', { round: 0.6 });
  blob(plan, 'body', [0, 0.30, 0.22], [0.12, 0.095, 0.12], 'chest', { round: 0.6 });
  blob(plan, 'body', [0, 0.295, 0.47], [0.072, 0.062, 0.075], 'head', { round: 0.5 });
  blob(plan, 'detail', [-0.05, 0.33, 0.47], [0.026, 0.028, 0.03], 'head');
  blob(plan, 'detail', [0.05, 0.33, 0.47], [0.026, 0.028, 0.03], 'head');
  // Antennae: a dial the generator could vary per seed.
  chain(plan, 'detail', ['antL0', 'antL1'],
    [[-0.035, 0.34, 0.52], [-0.075, 0.42, 0.62]], [0.011, 0.007],
    { parent: 'head', ringParts: 6, ringsPerSegment: 4 });
  chain(plan, 'detail', ['antR0', 'antR1'],
    [[0.035, 0.34, 0.52], [0.075, 0.42, 0.62]], [0.011, 0.007],
    { parent: 'head', ringParts: 6, ringsPerSegment: 4 });

  // Leg count is a seed axis, not a constant.
  //
  // The ticket asks for locomotion over "any-legged" characters, and that is only
  // demonstrated if the generator actually varies the count. Rows of legs are laid
  // along the body: 2 rows = 4 legs, 3 = 6, 4 = 8. Locomotion._setupGait derives
  // its phases from legs.length rather than assuming six, so 4 legs get a trot, 6 a
  // tripod and 8 a generic wave with no special-casing here.
  const rowCount = 2 + Math.floor(plan.rng.next() * 3);
  const bodyJoints = [['chest', 0.22], ['spine', 0.0], ['pelvis', -0.22]];
  const groups = [];
  for (let r = 0; r < rowCount; r++) {
    const t = rowCount === 1 ? 0.5 : r / (rowCount - 1);
    const z = 0.19 + (-0.21 - 0.19) * t;
    let parent = 'spine';
    let bestD = Infinity;
    for (const [n, jz] of bodyJoints) {
      const d = Math.abs(jz - z);
      if (d < bestD) { bestD = d; parent = n; }
    }
    // End rows splay slightly wider; the middle rows tuck under the body.
    const splay = 1 + 0.16 * Math.abs(t - 0.5) * 2;
    groups.push({
      suffix: String.fromCharCode(65 + r),
      parent,
      z,
      root: [0.112, 0.28, z],
      knee: [0.30 * splay, 0.30, z + (z > 0 ? 0.035 : -0.045)],
      foot: [0.37 * splay, 0.055, z + (z > 0 ? 0.01 : -0.07)],
      r: [0.052, 0.036, 0.028],
    });
  }
  const legs = [];
  for (const g of groups) {
    chain(plan, 'limbs', ['l' + g.suffix + '0', 'l' + g.suffix + '1', 'l' + g.suffix + '2'],
      [g.root, g.knee, g.foot], g.r,
      { sides: [1, -1], parent: g.parent, ringParts: 8, ringsPerSegment: 5, blend: 0.6 });
    for (const s of [1, -1]) {
      const sfx = s > 0 ? '_l' : '_r';
      blob(plan, 'limbs', [g.foot[0] * s, 0.05, g.foot[2]], [0.04, 0.032, 0.05], 'l' + g.suffix + '2' + sfx, { round: 0.6 });
    }
    legs.push({ hip: 'l' + g.suffix + '0_l', knee: 'l' + g.suffix + '1_l', ankle: 'l' + g.suffix + '2_l', side: 1, group: 0 });
    legs.push({ hip: 'l' + g.suffix + '0_r', knee: 'l' + g.suffix + '1_r', ankle: 'l' + g.suffix + '2_r', side: -1, group: 0 });
  }
  const nLegs = groups.length * 2;
  plan.title = 'Many-legged — ' + nLegs + ' legs, '
    + (nLegs === 4 ? 'trot' : nLegs === 6 ? 'tripod' : 'wave') + ' gait';
  plan.kin = {
    kind: 'hexapod',
    spine: 'spine',
    torso: 'chest',
    root: 'pelvis',
    head: 'head',
    legs,
    arms: [],
    speed: 1.3,
    gait: 'tripod',
    kneeSign: -1,
  };
  plan.meta = { height: 0.6 };
  return finalize(recenter(plan));
}

function hopper(seed) {
  const plan = makePlan(seed);
  plan.name = 'hopper';
  plan.title = 'Hopper — 0 legs, hop cycle';
  plan.palette = 'sand';
  part(plan, 'body', { kind: 'body' });
  part(plan, 'limbs', { kind: 'limb' });
  part(plan, 'detail', { kind: 'detail' });

  addJoint(plan, 'pelvis', [0, 0.21, 0], null, { radius: 0.11 });
  addJoint(plan, 'spine', [0, 0.31, 0.02], 'pelvis', { radius: 0.12 });
  addJoint(plan, 'chest', [0, 0.36, 0.06], 'spine', { radius: 0.13 });
  addJoint(plan, 'neck', [0, 0.40, 0.16], 'chest', { radius: 0.05 });
  addJoint(plan, 'head', [0, 0.44, 0.26], 'neck', { radius: 0.11 });

  blob(plan, 'body', [0, 0.21, 0], [0.135, 0.12, 0.135], 'pelvis', { round: 0.35 });
  blob(plan, 'body', [0, 0.30, 0.015], [0.14, 0.135, 0.15], 'spine', { round: 0.4 });
  blob(plan, 'body', [0, 0.36, 0.07], [0.12, 0.11, 0.115], 'chest', { round: 0.5 });
  blob(plan, 'body', [0, 0.445, 0.27], [0.095, 0.09, 0.105], 'head', { round: 0.5 });
  blob(plan, 'detail', [0, 0.415, 0.36], [0.05, 0.038, 0.045], 'head', { round: 0.6 });
  blob(plan, 'detail', [-0.062, 0.50, 0.255], [0.028, 0.03, 0.022], 'head');
  blob(plan, 'detail', [0.062, 0.50, 0.255], [0.028, 0.03, 0.022], 'head');

  // Fused legs: one chain, folded, with big feet — the hop is a body squash
  // cycle plus a knee extension, so no stepping is needed.
  chain(plan, 'limbs', ['hip', 'knee', 'ankle'],
    [[0.10, 0.20, -0.02], [0.155, 0.19, -0.12], [0.135, 0.055, -0.03]],
    [0.08, 0.062, 0.05],
    { sides: [1, -1], parent: 'pelvis', ringParts: 10, blend: 0.6 });
  for (const s of [1, -1]) {
    const sfx = s > 0 ? '_l' : '_r';
    blob(plan, 'limbs', [0.135 * s, 0.045, 0.02], [0.072, 0.045, 0.16], 'ankle' + sfx, { round: 0.5 });
  }
  // Little arms, kept for the "arms on everything" requirement.
  chain(plan, 'limbs', ['shoulder', 'hand'],
    [[0.105, 0.34, 0.06], [0.135, 0.275, 0.12]],
    [0.045, 0.035],
    { sides: [1, -1], parent: 'chest', ringParts: 8, ringsPerSegment: 4 });

  plan.kin = {
    kind: 'hopper',
    spine: 'spine',
    torso: 'chest',
    root: 'pelvis',
    head: 'head',
    legs: [],
    arms: [arm('shoulder_l', 'hand_l'), arm('shoulder_r', 'hand_r')],
    fusedLegs: [leg('hip_l', 'knee_l', 'ankle_l'), leg('hip_r', 'knee_r', 'ankle_r')],
    speed: 1.0,
    gait: 'hop',
    kneeSign: 1,
  };
  plan.meta = { height: 0.56 };
  return finalize(recenter(plan));
}

function flyer(seed) {
  const plan = makePlan(seed);
  plan.name = 'flyer';
  plan.title = 'Flyer — wings + arms';
  plan.palette = 'sky';
  part(plan, 'body', { kind: 'body' });
  part(plan, 'limbs', { kind: 'limb' });
  part(plan, 'detail', { kind: 'detail' });

  addJoint(plan, 'pelvis', [0, 0.52, -0.18], null, { radius: 0.09 });
  addJoint(plan, 'spine', [0, 0.545, 0.02], 'pelvis', { radius: 0.10 });
  addJoint(plan, 'chest', [0, 0.56, 0.20], 'spine', { radius: 0.11 });
  addJoint(plan, 'neck', [0, 0.60, 0.32], 'chest', { radius: 0.05 });
  addJoint(plan, 'head', [0, 0.63, 0.42], 'neck', { radius: 0.085 });
  addJoint(plan, 'tail', [0, 0.50, -0.30], 'pelvis', { radius: 0.04 });
  addJoint(plan, 'tailTip', [0, 0.475, -0.50], 'tail', { radius: 0.025 });

  blob(plan, 'body', [0, 0.52, -0.18], [0.11, 0.105, 0.13], 'pelvis', { round: 0.55 });
  blob(plan, 'body', [0, 0.55, 0.02], [0.105, 0.105, 0.16], 'spine', { round: 0.55 });
  blob(plan, 'body', [0, 0.565, 0.20], [0.10, 0.10, 0.12], 'chest', { round: 0.55 });
  blob(plan, 'body', [0, 0.635, 0.43], [0.075, 0.07, 0.09], 'head', { round: 0.5 });
  blob(plan, 'detail', [0, 0.615, 0.53], [0.032, 0.024, 0.045], 'head', { round: 0.6 });
  blob(plan, 'detail', [-0.055, 0.665, 0.42], [0.024, 0.026, 0.02], 'head');
  blob(plan, 'detail', [0.055, 0.665, 0.42], [0.024, 0.026, 0.02], 'head');
  for (const s of [1, -1]) {
    const sfx = s > 0 ? '_l' : '_r';
    blob(plan, 'detail', [0.10 * s, 0.60, 0.40], [0.05, 0.045, 0.06], 'head', { round: 0.4 });
  }
  chain(plan, 'detail', ['tail', 'tailTip'],
    [[0, 0.50, -0.30], [0, 0.472, -0.52]], [0.035, 0.02],
    { parent: 'pelvis', ringParts: 7, ringsPerSegment: 4, existing: true, jointBalls: false });

  // Wings: upperArm -> forearm -> wingTip, plus a thin membrane panel from the
  // hip to the wrist. Panels are the primitive that makes a wing read as a limb.
  chain(plan, 'limbs', ['upperArm', 'forearm', 'wingTip'],
    [[0.095, 0.575, 0.16], [0.30, 0.60, 0.10], [0.50, 0.575, 0.02]],
    [0.038, 0.028, 0.018],
    { sides: [1, -1], parent: 'chest', ringParts: 8, ringsPerSegment: 5, blend: 0.6 });
  for (const s of [1, -1]) {
    const sfx = s > 0 ? '_l' : '_r';
    panel(plan, 'limbs', [0.09 * s, 0.505, -0.10], [0.46 * s, 0.565, 0.06],
      0.012, 'forearm' + sfx);
  }
  // Small arms, held under the body.
  chain(plan, 'limbs', ['arm', 'hand'],
    [[0.075, 0.49, 0.16], [0.085, 0.415, 0.235]],
    [0.032, 0.024],
    { sides: [1, -1], parent: 'chest', ringParts: 7, ringsPerSegment: 4 });
  // Legs tucked under, for the "any-legged" dial and for landing poses.
  chain(plan, 'limbs', ['leg', 'toe'],
    [[0.065, 0.44, -0.02], [0.075, 0.345, 0.05]],
    [0.032, 0.022],
    { sides: [1, -1], parent: 'pelvis', ringParts: 7, ringsPerSegment: 4 });

  plan.kin = {
    kind: 'flyer',
    spine: 'spine',
    torso: 'chest',
    root: 'pelvis',
    head: 'head',
    tail: 'tail',
    legs: [],
    arms: [arm('arm_l', 'hand_l'), arm('arm_r', 'hand_r')],
    wings: [arm('upperArm_l', 'forearm_l'), arm('upperArm_r', 'forearm_r')],
    tuckedLegs: [leg('leg_l', 'toe_l', 'toe_l'), leg('leg_r', 'toe_r', 'toe_r')],
    speed: 1.0,
    gait: 'flap',
    kneeSign: -1,
  };
  plan.meta = { height: 0.75 };
  return finalize(recenter(plan));
}

// A thin stretched panel between two points — wing membrane, fin, ear.
function panel(plan, partName, from, to, thickness, boneName) {
  const mid = [(from[0] + to[0]) / 2, (from[1] + to[1]) / 2, (from[2] + to[2]) / 2];
  const dx = to[0] - from[0], dy = to[1] - from[1], dz = to[2] - from[2];
  const len = Math.hypot(dx, dy, dz);
  const b = plan.bones[boneName];
  return lump(plan, partName, mid, [len / 2, thickness, len * 0.34], {
    bone: boneName, subdiv: 2, round: 0.25,
  });
}

export const PRESET_BUILDERS = {
  biped,
  quadruped,
  hexapod,
  hopper,
  flyer,
};

export const PRESET_ORDER = ['biped', 'quadruped', 'hexapod', 'hopper', 'flyer'];

// The seed dial. Applied to every plan so that (preset, seed) really does
// produce a different creature: joint positions wander a little, radii breathe
// a little, and the palette rotates. Everything draws from the plan's own Rng,
// so the result is reproducible by construction.
// The seed. This is a GENERATOR, not a colour dial.
//
// The previous version moved every joint by 0.012-0.018 world units and scaled
// every radius by +-7%. Against a 1.9-unit biped that is under 1% of the
// silhouette: measured across five seeds the width/height ratio moved from 0.3685
// to 0.3714, i.e. 0.8%. Every seed looked identical apart from the palette.
//
// What actually reads as a different creature is PROPORTION, so that is what this
// varies: limb length, limb thickness, head size, stance width and torso
// blockiness, each drawn independently and each expressed as a RATIO so it means
// the same thing on a 0.39-unit flyer as on a 1.92-unit biped.
//
// Two constraints it must respect, both learned the hard way:
//   * limb joint chains are scaled about their ROOT joint, so a longer leg grows
//     downward from the hip rather than sliding the whole leg off the body;
//   * the torso's cross-section is scaled only modestly (0.90-1.12) because the
//     preset radii are the sizes the limb attachment points are laid out against.
//     A torso that outgrows its shoulder position swallows the arm (see BLOB_BULK).
function applySeed(plan) {
  const rng = plan.rng;
  const J = (name) => plan.bones[name];

  // Scale a joint chain about its root: every joint's offset from the previous one
  // is multiplied, so the chain grows away from the body and the attachment stays
  // put. `lateral` additionally scales side-to-side offsets, which is how stance
  // width and shoulder spread change.
  const scaleChain = (names, k, lateral = 1) => {
    for (let i = 1; i < names.length; i++) {
      const b = J(names[i]);
      const par = J(names[i - 1]);
      if (!b || !par) continue;
      for (let a = 0; a < 3; a++) {
        const d = b.joint[a] - par.joint[a];
        b.joint[a] = par.joint[a] + d * (a === 0 ? k * lateral : k);
      }
    }
    // Carry the whole chain sideways if the caller asked for a wider stance.
    if (lateral !== 1) {
      const root = J(names[0]);
      const par = root && root.parent >= 0 ? plan.joints[root.parent] : null;
      if (root && par) root.joint[0] = par.joint[0] + (root.joint[0] - par.joint[0]) * lateral;
    }
  };

  // Scale the tube radii of the shapes skinned to a joint chain, so a limb gets
  // thicker or thinner with its length rather than independently of it.
  const scaleChainRadii = (names, k) => {
    const idx = new Set(names.map((n) => J(n)).filter(Boolean).map((b) => b.index));
    for (const sh of plan.shapes) {
      if (!sh.bones || !sh.bones.some((bi) => idx.has(bi))) continue;
      if (sh.type === 'tube') {
        // Taper is preserved: scale every ring by the same factor.
        for (let i = 0; i < sh.radii.length; i++) sh.radii[i] *= k;
      } else {
        for (let i = 0; i < 3; i++) sh.radii[i] *= k;
      }
    }
  };

  const scaleBoneShapes = (name, k) => {
    const b = J(name);
    if (!b) return;
    for (const sh of plan.shapes) {
      if (sh.bones && sh.bones.includes(b.index)) {
        if (sh.type === 'tube') { for (let i = 0; i < sh.radii.length; i++) sh.radii[i] *= k; }
        else for (let i = 0; i < 3; i++) sh.radii[i] *= k;
      }
    }
  };

  const kin = plan.kin || {};
  const chains = [];
  for (const L of [...(kin.legs || []), ...(kin.fusedLegs || []), ...(kin.tuckedLegs || [])]) {
    chains.push([L.hip, L.knee, L.ankle].filter((n, i, a) => n && a.indexOf(n) === i));
  }
  for (const A of [...(kin.arms || []), ...(kin.wings || [])]) {
    chains.push([A.shoulder, A.elbow].filter((n, i, a) => n && a.indexOf(n) === i));
  }

  // 1. Per-limb proportions. Each limb draws its own pair, so a creature can come
  //    out long-legged and spindly or short-legged and stout, per limb.
  for (const chain of chains) {
    if (chain.length < 2) continue;
    const lenK = rng.range(0.62, 1.42);
    const thickK = rng.range(0.78, 1.30);
    // A long thin limb and a short fat one both look deliberate; tying thickness
    // loosely to length keeps them from fighting.
    scaleChain(chain, lenK, rng.range(0.92, 1.10));
    scaleChainRadii(chain, thickK);
  }

  // 2. Head size: the single biggest silhouette cue on a chunky creature.
  scaleBoneShapes(kin.head || 'head', rng.range(0.78, 1.34));

  // 3. Torso: length along the spine and modest cross-section change.
  const spine = J(kin.spine || 'spine');
  const root = J(kin.root || 'pelvis');
  const torso = J(kin.torso || 'chest');
  if (spine && root) {
    const k = rng.range(0.80, 1.30);
    const d = [spine.joint[0] - root.joint[0], spine.joint[1] - root.joint[1], spine.joint[2] - root.joint[2]];
    spine.joint[0] = root.joint[0] + d[0] * k; spine.joint[1] = root.joint[1] + d[1] * k; spine.joint[2] = root.joint[2] + d[2] * k;
    if (torso) {
      const d2 = [torso.joint[0] - spine.joint[0], torso.joint[1] - spine.joint[1], torso.joint[2] - spine.joint[2]];
      torso.joint[0] = spine.joint[0] + d2[0] * k; torso.joint[1] = spine.joint[1] + d2[1] * k; torso.joint[2] = spine.joint[2] + d2[2] * k;
      const head = J(kin.head || 'head');
      if (head && head.parent === torso.index) {
        const d3 = [head.joint[0] - torso.joint[0], head.joint[1] - torso.joint[1], head.joint[2] - torso.joint[2]];
        head.joint[0] = torso.joint[0] + d3[0] * k; head.joint[1] = torso.joint[1] + d3[1] * k; head.joint[2] = torso.joint[2] + d3[2] * k;
      }
    }
  }
  // Torso cross-section: keep this modest (see the BLOB_BULK note above).
  const bulk = rng.range(0.90, 1.12);
  for (const sh of plan.shapes) {
    if (sh.type !== 'lump' || !sh.bones) continue;
    const b = sh.bones[0];
    const isTorso = [root, spine, torso].some((j) => j && j.index === b);
    if (isTorso) for (let i = 0; i < 3; i++) sh.radii[i] *= bulk;
  }

  // 4. Residual jitter, now relative to the creature's own size rather than to
  //    absolute world units, so a flyer and a biped get the same visual amount.
  let h = 0;
  for (const b of plan.joints) h = Math.max(h, Math.abs(b.joint[1]));
  const unit = Math.max(0.05, h) * 0.012;
  for (const b of plan.joints) {
    const isFoot = /ankle|toe|foot/.test(b.name);
    const k = isFoot ? 0.4 : 1;
    b.joint[0] += rng.sym(unit) * k;
    b.joint[1] += rng.sym(unit * 1.4) * k;
    b.joint[2] += rng.sym(unit) * k;
  }
  for (const b of plan.joints) { b.rest[0] = b.joint[0]; b.rest[1] = b.joint[1]; b.rest[2] = b.joint[2]; }

  // 5. Palette last, and it is now one of several axes rather than the only one.
  const keys = Object.keys(PALETTES);
  const base = Math.max(0, keys.indexOf(plan.palette));
  plan.palette = keys[(base + Math.floor(rng.next() * keys.length)) % keys.length];
  plan.jittered = true;
  return plan;
}


export function buildPreset(name, seed) {
  const fn = PRESET_BUILDERS[name];
  if (!fn) throw new Error(`unknown preset "${name}"`);
  const plan = fn(`${name}:${seed}`);
  applySeed(plan);
  // Order matters twice here. The neck ball goes after applySeed so it tracks the
  // JITTERED neck joint, and after recenter so its centre is in the final frame —
  // recenter translates every existing shape, so a ball added before it keeps its
  // pre-recenter coordinate and ends up offset by the recenter distance (measured:
  // 66 body vertices at y = 3.47 on a 2.0-unit-tall character).
  recenter(plan);
  neckBall(plan);
  return finalize(plan);
}
