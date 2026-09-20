// AC-0090 — the procedural body plan.
//
// A character is DATA, not a model: a graph of joints, plus a list of primitive
// shapes (tapered tubes, ellipsoids, rounded boxes) placed against those joints.
// Everything downstream — skin weights, the toon shader, the locomotion rig —
// reads this structure, so a new creature is a new plan (or a new seed), never
// new code.
//
// Coordinate convention: +Y up, +Z is the character's FORWARD, +X is its left.
// A "bone" in this prototype is just a joint plus its parent chain; its origin
// is the joint, so a local bone rotation is a rotation about world-aligned axes
// centred on that joint. That keeps the animation code readable (see mat4.js).

import { Rng } from './rng.js';

export function makePlan(nameSeed) {
  const rng = new Rng(nameSeed);
  return {
    seed: nameSeed,
    rng,
    name: '',
    title: '',
    joints: [],
    bones: {},      // name -> joint record; a map, not an array
    shapes: [],
    parts: {},      // name -> part; a map, not an array (shapes index separately)
    kin: { kind: 'biped', legs: [], arms: [], spine: 'spine', speed: 1, gait: 'walk' },
    meta: {},
  };
}

// ---------------------------------------------------------------- joints ----

export function addJoint(plan, name, pos, parent, opts = {}) {
  if (plan.bones[name]) throw new Error(`duplicate joint "${name}"`);
  const index = plan.joints.length;
  const parentIndex = parent ? plan.bones[parent].index : -1;
  const bone = {
    index,
    name,
    parent: parentIndex,
    parentName: parent || null,
    joint: pos.slice(),
    rest: pos.slice(),
    radius: opts.radius ?? 0.04,
    visible: opts.visible !== false, // false => exists for skinning, not drawn
  };
  plan.joints.push(bone);
  plan.bones[name] = bone;
  return bone;
}

// Shapes live in ONE list (plan.shapes) with a part id on each; `part()` also
// hands back a per-part array that pushes into that same list, so there is no
// second copy to fall out of sync.
export function part(plan, name, opts = {}) {
  if (plan.parts[name]) throw new Error(`duplicate part "${name}"`);
  const p = {
    name,
    kind: opts.kind || 'body',
    bone: opts.bone ?? null,
    index: Object.keys(plan.parts).length,
    shapes: [],
  };
  plan.parts[name] = p;
  return p;
}

function registerShape(plan, partName, shape) {
  const p = plan.parts[partName];
  if (!p) throw new Error(`no part "${partName}"`);
  plan.shapes.push(shape);
  p.shapes.push(shape);
  return shape;
}

// ---------------------------------------------------------------- shapes ----

// A tapered tube: a smooth centreline through `points` (one point per joint of a
// limb chain) with a radius profile r(t) driven by `radii`, one per point.
// This is the primary character primitive — it is a limb *and* the joint filler,
// which is why it can span a joint without a visible seam (see skin.js).
export function tube(plan, partName, points, radii, opts = {}) {
  const p = plan.parts[partName];
  if (!p) throw new Error(`tube: no part "${partName}"`);
  const boneNames = opts.bones || [];
  const boneIdx = boneNames.map((n) => {
    const b = plan.bones[n];
    if (!b) throw new Error(`tube "${partName}": no joint "${n}"`);
    return b.index;
  });
  const shape = {
    type: 'tube',
    points: points.map((q) => q.slice()),
    radii: radii.slice(),
    bones: boneIdx,
    // Where along t each joint sits, so the tube's tessellation can put dense
    // rings right at the joints (the blend windows live there).
    jointT: opts.jointT || null,
    parts: opts.ringParts ?? 12,
    blend: opts.blend ?? 0.55, // weight-blend half-width as a fraction of a segment
    smooth: opts.smooth ?? 0,
    capsuleCap: opts.capsuleCap !== false,
    material: opts.material || 0,
  };
  return registerShape(plan, partName, shape);
}

// Ellipsoid / superellipsoid lump: torso volumes, bellies, shoulders, heads.
// `round` 0 = box, 1 = full ellipsoid; values in between give the soft
// rounded-box read that keeps the "assembled from primitives" language.
export function lump(plan, partName, centre, radii, opts = {}) {
  const p = plan.parts[partName];
  if (!p) throw new Error(`lump: no part "${partName}"`);
  const b = plan.bones[opts.bone];
  const shape = {
    type: 'lump',
    centre: centre.slice(),
    radii: radii.slice(),
    round: opts.round ?? 1,
    bones: b ? [b.index] : [],
    subdiv: opts.subdiv ?? 2,
    material: opts.material || 0,
    blend: opts.blend ?? 0,
  };
  return registerShape(plan, partName, shape);
}

// A limb chain helper: joints in a row, mirrored if x != 0, with radii that
// taper along the chain. Returns the joint names so the plan can wire kin.
export function limb(plan, partName, names, points, radii, opts = {}) {
  const joints = [];
  const sides = opts.sides || [1];
  for (const side of sides) {
    const suffix = sides.length > 1 ? (side > 0 ? '_l' : '_r') : '';
    const parentFor = (i) => (i === 0 ? opts.parent : names[i - 1] + suffix);
    const chainPts = [];
    const chainRadii = [];
    for (let i = 0; i < names.length; i++) {
      const jn = names[i] + suffix;
      const pos = [points[i][0] * (side === 0 ? 1 : side), points[i][1], points[i][2]];
      addJoint(plan, jn, pos, parentFor(i), { radius: radii[i] });
      chainPts.push(pos);
      chainRadii.push(radii[i]);
      joints.push(jn);
    }
    tube(plan, partName, chainPts, chainRadii, {
      bones: names.map((n) => n + suffix).concat(opts.tip ? [opts.tip + suffix] : []),
      ringParts: opts.ringParts ?? 12,
      blend: opts.blend ?? 0.55,
      material: opts.material || 0,
      capsuleCap: opts.capsuleCap !== false,
    });
    // A joint ball at each articulation: the primitive that makes the limb-to-
    // torso transition volumetric instead of a hard cylinder butt.
    if (opts.jointBalls !== false) {
      for (let i = 0; i < names.length; i++) {
        if (i === 0 && opts.rootBall === false) continue;
        const jn = names[i] + suffix;
        const r = radii[i] * (i === names.length - 1 ? 1.0 : 0.98);
        lumplet(plan, partName, points[i], side, r, jn, opts.material || 0);
      }
    }
  }
  return joints;
}

function lumplet(plan, partName, point, side, r, boneName, material) {
  const b = plan.bones[boneName];
  lump(plan, partName, [point[0] * (side === 0 ? 1 : side), point[1], point[2]],
    [r * 1.06, r * 1.06, r * 1.06], { bone: boneName, subdiv: 1, material, round: 1 });
  return b;
}

// ------------------------------------------------------------- finalise ----

// Compute derived, plan-level facts the rest of the pipeline relies on:
// bounding box, an overall scale, and the list of joints that are safe to
// animate (a joint with no parent cannot be posed).
export function finalize(plan) {
  let min = [Infinity, Infinity, Infinity];
  let max = [-Infinity, -Infinity, -Infinity];
  const consider = (q, r) => {
    for (let i = 0; i < 3; i++) {
      min[i] = Math.min(min[i], q[i] - r);
      max[i] = Math.max(max[i], q[i] + r);
    }
  };
  for (const s of plan.shapes) {
    if (s.type === 'tube') {
      for (let i = 0; i < s.points.length; i++) consider(s.points[i], s.radii[i]);
    } else {
      const r = Math.max(s.radii[0], s.radii[1], s.radii[2]);
      consider(s.centre, r);
    }
  }
  plan.bbox = { min, max, size: [max[0] - min[0], max[1] - min[1], max[2] - min[2]] };
  plan.centroid = [(min[0] + max[0]) / 2, (min[1] + max[1]) / 2, (min[2] + max[2]) / 2];
  plan.groundY = min[1];
  plan.topY = max[1];
  plan.height = max[1] - min[1];
  plan.tubeCount = plan.shapes.filter((s) => s.type === 'tube').length;
  plan.lumpCount = plan.shapes.filter((s) => s.type === 'lump').length;
  return plan;
}

// Move every joint and shape so the character's feet sit on y = 0 and its
// centre of mass sits over the origin. Uniform across all body plans so the
// demo can line them up.
export function recenter(plan) {
  // Measure first: recenter() is called BEFORE finalize() in the presets, so it
  // must not assume the derived metrics already exist.
  finalize(plan);
  const dx = -plan.centroid[0];
  const dy = -plan.bbox.min[1];
  const dz = -plan.centroid[2];
  for (const b of plan.joints) {
    b.joint[0] += dx; b.joint[1] += dy; b.joint[2] += dz;
    b.rest[0] = b.joint[0]; b.rest[1] = b.joint[1]; b.rest[2] = b.joint[2];
  }
  for (const s of plan.shapes) {
    if (s.type === 'tube') {
      for (const q of s.points) { q[0] += dx; q[1] += dy; q[2] += dz; }
    } else {
      s.centre[0] += dx; s.centre[1] += dy; s.centre[2] += dz;
    }
  }
  finalize(plan);
  return plan;
}
