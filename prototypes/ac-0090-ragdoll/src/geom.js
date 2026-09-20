// AC-0090 — primitive geometry generation.
//
// Two primitives, both generated to be *deformation-friendly* rather than to be
// separate objects:
//
//   tube  — a smooth centreline through a limb's joint chain with a radius
//           profile r(t). It spans several bones, so it crosses each joint as
//           ONE continuous surface instead of two cylinders butting together.
//           This is what removes the classic ragdoll seam.
//   lump  — a superellipsoid (round 1 = ellipsoid, round 0 = rounded box).
//           Torso volumes, bellies, heads, feet, hands, eyes.
//
// Every shape is emitted in character space with `bi` (bone indices) and `bw`
// (weights) attributes already baked, so the shader only has to apply them.

import { m4, m4mul, m4invert, m4xformPoint } from './mat4.js';

// ------------------------------------------------------------- primitives ---

export function icosphere(subdiv) {
  const t = (1 + Math.sqrt(5)) / 2;
  let verts = [
    [-1, t, 0], [1, t, 0], [-1, -t, 0], [1, -t, 0],
    [0, -1, t], [0, 1, t], [0, -1, -t], [0, 1, -t],
    [t, 0, -1], [t, 0, 1], [-t, 0, -1], [-t, 0, 1],
  ];
  let faces = [
    [0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11],
    [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
    [3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
    [4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1],
  ];
  for (let s = 0; s < subdiv; s++) {
    const cache = new Map();
    const next = [];
    const midpoint = (a, b) => {
      const key = a < b ? a * 1e6 + b : b * 1e6 + a;
      let m = cache.get(key);
      if (m !== undefined) return m;
      const va = verts[a], vb = verts[b];
      m = verts.length;
      verts.push([(va[0] + vb[0]) / 2, (va[1] + vb[1]) / 2, (va[2] + vb[2]) / 2]);
      cache.set(key, m);
      return m;
    };
    for (const [a, b, c] of faces) {
      const ab = midpoint(a, b), bc = midpoint(b, c), ca = midpoint(c, a);
      next.push([a, ab, ca], [b, bc, ab], [c, ca, bc], [ab, bc, ca]);
    }
    faces = next;
  }
  const norm = verts.map((v) => {
    const l = Math.hypot(v[0], v[1], v[2]) || 1;
    return [v[0] / l, v[1] / l, v[2] / l];
  });
  return { dirs: norm, faces };
}

// Superellipsoid radial factor for a unit direction. `round` 1 => sphere, lower
// => boxier; the dial is what keeps the boxy parts reading as soft primitives.
//
// The surface is  |x/rx|^e + |y/ry|^e + |z/rz|^e = 1  with  e = 2/round, so
// e = 2 is a sphere and large e approaches a box. The ray t*n crosses it at
//
//     t = ( |nx|^e + |ny|^e + |nz|^e ) ^ (-1/e)
//
// which is the reciprocal of the L^e norm — and that reciprocal is what makes the
// shape FILL its bounding box: t = 1 along a face normal and t -> 1.26 on a corner
// for e = 8. The earlier revision used the positive power instead, i.e. the
// reciprocal of the correct answer, which shrank every character's volume to a
// few percent of its bounding box while leaving a plausible-looking silhouette.
function shapeFactor(nx, ny, nz, round) {
  if (round >= 0.999) return 1;
  const e = 2 / Math.max(0.15, round);
  const a = Math.pow(Math.abs(nx), e);
  const b = Math.pow(Math.abs(ny), e);
  const c = Math.pow(Math.abs(nz), e);
  const sum = a + b + c;
  if (sum <= 1e-12) return 1;
  return Math.pow(sum, -1 / e);
}

// The implicit field of the same superellipsoid about its centre, used ONLY to
// get the surface normal by central differences. It must be a real function of
// position — an earlier version differenced `shapeFactor - 1`, which is identically
// zero on the surface, so every gradient came out as 0/0 and every lump normal
// became (1,0,0). The mesh still looked closed and its face normals still agreed
// with the vertex normals, because accumulateNormals rebuilds them from the faces
// afterwards; the surface just shaded as if lit from one direction.
function lumpField(shape, x, y, z) {
  const e = shape.round >= 0.999 ? 2 : 2 / Math.max(0.15, shape.round);
  const rx = Math.max(1e-6, shape.radii[0]);
  const ry = Math.max(1e-6, shape.radii[1]);
  const rz = Math.max(1e-6, shape.radii[2]);
  return Math.pow(Math.abs(x / rx), e) + Math.pow(Math.abs(y / ry), e) +
    Math.pow(Math.abs(z / rz), e) - 1;
}

// A mirrored primitive (x -> -x) reverses its ring winding, because the tangent
// flips sign with the direction. Left unchecked the right-hand half of every
// character renders inside-out (invisible under back-face culling) and its
// shading normals point into the body.
//
// Orientation test: the divergence-theorem sum  S = Sum of c.n over the shape's
// own triangles (c = face centre, n = e1 x e2, the outward normal for a
// counter-clockwise winding). On a closed surface S = 3 * volume, so S < 0 means
// this shape's winding is inverted and every one of its triangles must be
// reversed.
//
// Two earlier revisions of this function were WRONG in a way worth recording:
// both computed a signed volume relative to a fixed reference point (first the
// world origin, then the shape centroid). A relative volume is only an
// orientation test for a surface that ENCLOSES the reference point, which no
// limb does, so both reported "correct" while half the body was inverted and the
// total mesh volume still came out positive. The sum below is reference-free.
function fixShapeWinding(out, idxStart) {
  const p = out.positions;
  const iEnd = out.indices.length;
  if (iEnd <= idxStart + 2) return false;
  let s3 = 0;
  for (let i = idxStart; i < iEnd; i += 3) {
    const a = out.indices[i] * 3, b = out.indices[i + 1] * 3, c = out.indices[i + 2] * 3;
    const e1x = p[b] - p[a], e1y = p[b + 1] - p[a + 1], e1z = p[b + 2] - p[a + 2];
    const e2x = p[c] - p[a], e2y = p[c + 1] - p[a + 1], e2z = p[c + 2] - p[a + 2];
    const nx = e1y * e2z - e1z * e2y;
    const ny = e1z * e2x - e1x * e2z;
    const nz = e1x * e2y - e1y * e2x;
    const cx = (p[a] + p[b] + p[c]) / 3;
    const cy = (p[a + 1] + p[b + 1] + p[c + 1]) / 3;
    const cz = (p[a + 2] + p[b + 2] + p[c + 2]) / 3;
    s3 += cx * nx + cy * ny + cz * nz;
  }
  if (s3 >= 0) return false;
  out.windingFlips = (out.windingFlips || 0) + 1;
  for (let i = idxStart; i < iEnd; i += 3) {
    const t = out.indices[i + 1];
    out.indices[i + 1] = out.indices[i + 2];
    out.indices[i + 2] = t;
  }
  return true;
}

// Find the weights of the chain vertex nearest a lump's centre. `chain` is the
// skin table recorded by buildTube for the tube this lump articulates with.
function pickSkin(chain, positions, from, to) {
  if (!chain || chain.vertexEnd <= chain.vertexStart) return null;
  let cx = 0, cy = 0, cz = 0;
  for (let i = from; i < to; i++) { cx += positions[i * 3]; cy += positions[i * 3 + 1]; cz += positions[i * 3 + 2]; }
  const n = Math.max(1, to - from);
  cx /= n; cy /= n; cz /= n;
  let best = Infinity;
  let bestV = -1;
  for (let v = chain.vertexStart; v < chain.vertexEnd; v++) {
    const dx = positions[v * 3] - cx;
    const dy = positions[v * 3 + 1] - cy;
    const dz = positions[v * 3 + 2] - cz;
    const d = dx * dx + dy * dy + dz * dz;
    if (d < best) { best = d; bestV = v; }
  }
  if (bestV < 0) return null;
  const out = [];
  for (let q = 0; q < 4; q++) {
    const w = chain.bw[bestV * 4 + q];
    if (w > 0) out.push([chain.bi[bestV * 4 + q], w]);
  }
  return out.length ? out : null;
}

// ---------------------------------------------------------- centreline -----

const SMOOTHSTEP = (x) => x * x * (3 - 2 * x);

// Centripetal-ish Catmull-Rom through `pts`, clamped at the ends. A smooth C1
// centreline is what lets the radius profile cross a joint without a crease.
//
// `out` MUST NOT alias any element of `pts`: `p1 = pts[seg]` is read inside the
// loop that writes `out`, so a shared scratch buffer overwrites the curve's own
// control points mid-evaluation. That is not hypothetical — it shipped here, and
// because callers passed `shape.points[i]` as the scratch it silently rewrote
// each limb's joint positions as it tessellated, leaving every second limb with
// degenerate joint arcs (hence zero-length blend windows and unskinned bones).
const CURVE_SCRATCH = [0, 0, 0];

export function curveAt(pts, t, out) {
  const o = out === undefined ? CURVE_SCRATCH : out;
  const n = pts.length;
  if (n === 1) { o[0] = pts[0][0]; o[1] = pts[0][1]; o[2] = pts[0][2]; return o; }
  const seg = Math.min(n - 2, Math.max(0, Math.floor(t * (n - 1))));
  const local = t * (n - 1) - seg;
  const p0 = pts[Math.max(0, seg - 1)];
  const p1 = pts[seg];
  const p2 = pts[Math.min(n - 1, seg + 1)];
  const p3 = pts[Math.min(n - 1, seg + 2)];
  const t2 = local * local, t3 = t2 * local;
  for (let i = 0; i < 3; i++) {
    o[i] = 0.5 * ((2 * p1[i]) + (-p0[i] + p2[i]) * local +
      (2 * p0[i] - 5 * p1[i] + 4 * p2[i] - p3[i]) * t2 +
      (-p0[i] + 3 * p1[i] - 3 * p2[i] + p3[i]) * t3);
  }
  return o;
}

// Radius along the same parameter. Linear between joint radii; it is the SHAPE of
// this profile that makes a joint read as one piece, not a separate ball.
export function radiusAt(radii, t, scale = 1) {
  const n = radii.length;
  if (n === 1) return radii[0] * scale;
  const seg = Math.min(n - 2, Math.max(0, Math.floor(t * (n - 1))));
  const local = t * (n - 1) - seg;
  const a = radii[seg], b = radii[Math.min(n - 1, seg + 1)];
  // Smooth the handover so the silhouette does not kink at a control point.
  return (a + (b - a) * SMOOTHSTEP(local)) * scale;
}

export function curveSamples(points, radii, n) {
  const pts = [];
  const rad = [];
  for (let i = 0; i <= n; i++) {
    const t = i / n;
    const tmp = curveAt(points, t);
    pts.push([tmp[0], tmp[1], tmp[2]]);
    rad.push(radiusAt(radii, t));
  }
  return { pts, radii: rad };
}

// Rotation-minimising frames along the sampled centreline (parallel transport).
// Building the rings from a fixed up-vector instead would spin the cross-section
// wherever the limb runs near-vertical, which shows up as a visible twist at the
// joints of a leg.
export function frames(points, radii, samples) {
  const n = samples + 1;
  const pos = new Float32Array(n * 3);
  const tan = new Float32Array(n * 3);
  const nor = new Float32Array(n * 3);
  const bin = new Float32Array(n * 3);
  for (let i = 0; i < n; i++) {
    const t = i / (n - 1);
    const tmp = curveAt(points, t);
    pos[i * 3] = tmp[0]; pos[i * 3 + 1] = tmp[1]; pos[i * 3 + 2] = tmp[2];
  }
  // Tangents by central difference, so the ends are not biased inward.
  for (let i = 0; i < n; i++) {
    const a = Math.max(0, i - 1) * 3, b = Math.min(n - 1, i + 1) * 3;
    let tx = pos[b] - pos[a], ty = pos[b + 1] - pos[a + 1], tz = pos[b + 2] - pos[a + 2];
    const l = Math.hypot(tx, ty, tz) || 1;
    tan[i * 3] = tx / l; tan[i * 3 + 1] = ty / l; tan[i * 3 + 2] = tz / l;
  }
  // Seed the first frame with any vector not parallel to the tangent.
  let ux = 0, uy = 1, uz = 0;
  if (Math.abs(tan[1]) > 0.9) { ux = 1; uy = 0; uz = 0; }
  for (let i = 0; i < n; i++) {
    const tx = tan[i * 3], ty = tan[i * 3 + 1], tz = tan[i * 3 + 2];
    // Project the carried normal onto the plane perpendicular to this tangent.
    const d = ux * tx + uy * ty + uz * tz;
    let nx = ux - d * tx, ny = uy - d * ty, nz = uz - d * tz;
    let l = Math.hypot(nx, ny, nz);
    if (l < 1e-6) {
      // Degenerate carry (tangent reversed): fall back to a fresh perpendicular.
      nx = Math.abs(tz) < 0.9 ? -tz : tx; ny = 0; nz = Math.abs(tz) < 0.9 ? tx : -ty;
      l = Math.hypot(nx, ny, nz) || 1;
    }
    nx /= l; ny /= l; nz /= l;
    nor[i * 3] = nx; nor[i * 3 + 1] = ny; nor[i * 3 + 2] = nz;
    // binormal = tangent x normal, right-handed with the outward ring winding.
    bin[i * 3] = ty * nz - tz * ny;
    bin[i * 3 + 1] = tz * nx - tx * nz;
    bin[i * 3 + 2] = tx * ny - ty * nx;
    ux = nx; uy = ny; uz = nz;
  }
  return { pos, tan, nor, bin, n };
}

// --------------------------------------------------------- tessellation -----

// Rings around the circumference, from the shape's own radius relative to the
// character's height: a 2 cm finger must not cost what a 20 cm torso does.
function ringCountFor(radius, tess, shape) {
  if (shape.rings) return shape.rings;
  // Ring count from the shape's radius as a FRACTION OF THE CHARACTER'S HEIGHT,
  // so the whole body is budgeted on one scale and a small creature does not spend
  // the same ring count on a 2 cm finger as a large one spends on its torso.
  const rel = radius / Math.max(1e-6, tess.height);
  return Math.max(5, Math.min(12, Math.round((5 + rel * 60) * tess.budget)));
}

function ringsPerSegmentFor(radius, tess, shape) {
  if (shape.ringsPerSegment) return shape.ringsPerSegment;
  const rel = radius / Math.max(1e-6, tess.height);
  return Math.max(3, Math.min(10, Math.round((5 + rel * 44) * tess.budget)));
}

// A tessellation plan derived once per character so every shape is budgeted
// against the same scale.
export function tessellationFor(plan, budget = 1) {
  let height = plan.height || 0;
  if (!height) {
    let max = -Infinity, min = Infinity;
    for (const s of plan.shapes) {
      const ys = s.type === 'tube' ? s.points.map((q) => q[1]) : [s.centre[1]];
      for (const y of ys) { max = Math.max(max, y); min = Math.min(min, y); }
    }
    height = Math.max(1e-3, max - min);
  }
  return { height, budget: Math.max(0.25, budget), scale: 1 / Math.max(1e-3, height) };
}

// ------------------------------------------------------------ tube build ---

// Fraction of the shorter neighbouring bone that a joint's blend window may
// occupy. 0.5 means adjacent windows meet exactly at the bone's midpoint.
const HALF_BONE_BLEND = 0.5;

export function buildTube(shape, geomOpts, out) {
  const { radiusScale, tess } = geomOpts;
  const idxStart = out.indices.length;
  const vertexStart = out.vWrite;
  const meanR = shape.radii.reduce((a, b) => a + b, 0) / shape.radii.length;
  const ring = ringCountFor(meanR * radiusScale, tess, shape);
  const ringsPerSegment = ringsPerSegmentFor(meanR * radiusScale, tess, shape);
  const samples = Math.max(3, Math.round((shape.points.length - 1) * ringsPerSegment));
  const f = frames(shape.points, shape.radii, samples);
  const nn = f.n;
  const rad = new Float32Array(nn);
  for (let i = 0; i < nn; i++) {
    rad[i] = Math.max(1e-4, radiusAt(shape.radii, i / (nn - 1), radiusScale));
  }
  // Arc length along the centreline, and the arc position of each JOINT, so the
  // weight blend can be centred on the joint rather than on the parameter.
  const arc = new Float64Array(nn);
  for (let i = 1; i < nn; i++) {
    arc[i] = arc[i - 1] + Math.hypot(
      f.pos[i * 3] - f.pos[(i - 1) * 3],
      f.pos[i * 3 + 1] - f.pos[(i - 1) * 3 + 1],
      f.pos[i * 3 + 2] - f.pos[(i - 1) * 3 + 2],
    );
  }
  const arcTotal = arc[nn - 1] || 1;
  const nJoints = shape.points.length;
  const jointArc = new Float64Array(nJoints);
  for (let q = 0; q < nJoints; q++) {
    const t = nJoints === 1 ? 0 : q / (nJoints - 1);
    const si = t * (nn - 1);
    const i0 = Math.min(nn - 2, Math.max(0, Math.floor(si)));
    const frac = si - i0;
    jointArc[q] = (arc[i0] + (arc[i0 + 1] - arc[i0]) * frac) / arcTotal;
  }
  const radiusFraction = Math.min(0.45, Math.max(0.02, meanR * 2.2 / Math.max(1e-6, arcTotal)));

  // Row plan, in emission order: the start pole, the start cap opening to
  // cos = 0.5, every body ring including both rims, then the end cap closing from
  // cos = 0.5 to the end pole. The first and last rows are therefore the two
  // poles, which is exactly what the fans below assume.
  const capSegs = shape.capsuleCap === false ? 0 : 3;
  const rows = [];
  if (capSegs > 0) rows.push({ i: 0, dir: 'start', cos: 0, sin: 1 });
  for (let c = 1; c < capSegs; c++) {
    const a = (c / capSegs) * (Math.PI / 2);
    rows.push({ i: 0, dir: 'start', cos: Math.cos(a), sin: Math.sin(a) });
  }
  for (let i = 0; i < nn; i++) rows.push({ i, dir: 'body', cos: 1, sin: 0 });
  for (let c = capSegs - 1; c >= 1; c--) {
    const a = (c / capSegs) * (Math.PI / 2);
    rows.push({ i: nn - 1, dir: 'end', cos: Math.cos(a), sin: Math.sin(a) });
  }
  if (capSegs > 0) rows.push({ i: nn - 1, dir: 'end', cos: 0, sin: 1 });

  const rings = [];
  for (const row of rows) {
    const i = row.i;
    const px = f.pos[i * 3], py = f.pos[i * 3 + 1], pz = f.pos[i * 3 + 2];
    const nxv = f.nor[i * 3], nyv = f.nor[i * 3 + 1], nzv = f.nor[i * 3 + 2];
    const bxv = f.bin[i * 3], byv = f.bin[i * 3 + 1], bzv = f.bin[i * 3 + 2];
    const txv = f.tan[i * 3], tyv = f.tan[i * 3 + 1], tzv = f.tan[i * 3 + 2];
    const r = rad[i];
    const axial = row.dir === 'start' ? -r * row.sin : row.dir === 'end' ? r * row.sin : 0;
    const ringR = r * row.cos;
    // LOCAL index of this row's first vertex within the shape. `vertexStart` is
    // added for weight writes and for the index buffer, so recording a global
    // index here double-counts the shape's offset — which is why every tube after
    // the first in a part ended up with no weights at all.
    const first = out.positions.length / 3 - vertexStart;
    // A pole row has radius 0, so every one of its `ring` samples lands on the
    // SAME point. Emit a single vertex there and cap it at its neighbour ring.
    const emit = row.cos < 1e-9 ? 1 : ring;
    for (let k = 0; k < emit; k++) {
      const a = (k / ring) * Math.PI * 2;
      const ca = Math.cos(a), sa = Math.sin(a);
      const ox = nxv * ca + bxv * sa;
      const oy = nyv * ca + byv * sa;
      const oz = nzv * ca + bzv * sa;
      // The cap's surface normal is the spherical normal, not the radial one.
      let snx = ox * row.cos + txv * (row.dir === 'start' ? -row.sin : row.sin);
      let sny = oy * row.cos + tyv * (row.dir === 'start' ? -row.sin : row.sin);
      let snz = oz * row.cos + tzv * (row.dir === 'start' ? -row.sin : row.sin);
      const sl = Math.hypot(snx, sny, snz) || 1;
      snx /= sl; sny /= sl; snz /= sl;
      out.positions.push(
        px + ox * ringR + txv * axial,
        py + oy * ringR + tyv * axial,
        pz + oz * ringR + tzv * axial,
      );
      out.smoothNormals.push(snx, sny, snz);
      out.partIds.push(shape.partId);
      out.uv.push(k / ring, i / (nn - 1));
    }
    rings.push({ start: first, count: emit });
  }

  // Row 0 and the last row are the poles (see the row plan above).
  const pole0 = vertexStart + rings[0].start;
  const r1 = rings[1];
  for (let k = 0; k < r1.count; k++) {
    const k2 = (k + 1) % r1.count;
    out.indices.push(pole0, vertexStart + r1.start + k2, vertexStart + r1.start + k);
  }
  const last = rings.length - 1;
  const poleN = vertexStart + rings[last].start;
  const rN = rings[last - 1];
  for (let k = 0; k < rN.count; k++) {
    const k2 = (k + 1) % rN.count;
    out.indices.push(poleN, vertexStart + rN.start + k, vertexStart + rN.start + k2);
  }
  // Everything between the caps is a plain quad strip between consecutive rows.
  for (let r = 1; r < rings.length - 2; r++) {
    const a0 = vertexStart + rings[r].start;
    const b0 = vertexStart + rings[r + 1].start;
    const cnt = rings[r].count;
    for (let k = 0; k < cnt; k++) {
      const k2 = (k + 1) % cnt;
      const i0 = a0 + k, i1 = a0 + k2, i2 = b0 + k2, i3 = b0 + k;
      out.indices.push(i0, i1, i2, i0, i2, i3);
    }
  }

  fixShapeWinding(out, idxStart);
  const nnBones = shape.bones.length;
  if (nnBones === 0) {
    out.vWrite = out.positions.length / 3;
    return;
  }
  // Weights from ARC LENGTH, with the blend window CENTRED ON EACH JOINT.
  //
  // Two earlier revisions were wrong and both looked fine in a still frame:
  //   (a) mapping the uniform curve parameter straight onto a joint index, which
  //       put the window in the wrong place because the joints are not equally
  //       spaced along the curve;
  //   (b) blending across a segment's first/last fraction — not centred on the
  //       joint, so a ring sitting exactly on the joint got the wrong mix.
  // The test that catches both is edge stretch under animation.
  for (let r = 0; r < rows.length; r++) {
    const row = rows[r];
    const sPar = arc[row.i] / arcTotal;
    let j = 0;
    let best = Infinity;
    for (let q = 0; q < nJoints; q++) {
      const d = Math.abs(jointArc[q] - sPar);
      if (d < best) { best = d; j = q; }
    }
    const d = sPar - jointArc[j];
    // The window may reach at most HALF the shorter neighbouring bone: two
    // adjacent joints then have non-overlapping windows by construction. Letting
    // the window exceed the bone turns the whole bone into a transition, so
    // vertices a few millimetres apart carry very different weights and the bone
    // stretches badly when the joint rotates.
    const gPrev = j > 0 ? jointArc[j] - jointArc[j - 1] : Infinity;
    const gNext = j < nJoints - 1 ? jointArc[j + 1] - jointArc[j] : Infinity;
    const gap = Math.min(gPrev, gNext);
    const w = Math.min(shape.blendWindow ?? radiusFraction,
      Number.isFinite(gap) ? gap * HALF_BONE_BLEND : 1);
    let a = 1;
    let other = j;
    if (d < 0) {
      other = Math.max(0, j - 1);
      a = other === j ? 1 : 0.5 * (1 + SMOOTHSTEP(Math.max(0, 1 + d / w)));
    } else if (d > 0) {
      other = Math.min(nJoints - 1, j + 1);
      a = other === j ? 1 : 0.5 * (1 + SMOOTHSTEP(Math.max(0, 1 - d / w)));
    }
    const w0 = shape.bones[j] ?? shape.bones[0];
    const w1 = shape.bones[other] ?? w0;
    const ringInfo = rings[r];
    for (let k = 0; k < ringInfo.count; k++) {
      const vi = vertexStart + ringInfo.start + k;
      out.bi[vi * 4] = w0; out.bw[vi * 4] = a;
      out.bi[vi * 4 + 1] = w1; out.bw[vi * 4 + 1] = 1 - a;
      out.bi[vi * 4 + 2] = 0; out.bw[vi * 4 + 2] = 0;
      out.bi[vi * 4 + 3] = 0; out.bw[vi * 4 + 3] = 0;
    }
  }
  out.vWrite = out.positions.length / 3;
  // Hand the weighting tables to the shape: the joint balls that sit ON this
  // chain borrow their weights from the nearest chain vertex, so the ball and the
  // tube move together instead of the rigid ball tearing off the blended tube.
  shape._skin = {
    vertexStart,
    vertexEnd: out.vWrite,
    positions: out.positions,
    bi: out.bi,
    bw: out.bw,
  };
  out.boneCount = Math.max(out.boneCount, ...shape.bones.map((b) => b + 1));
}

// ------------------------------------------------------------ lump build ---

const SPHERE_CACHE = new Map();
function sphere(subdiv) {
  let s = SPHERE_CACHE.get(subdiv);
  if (!s) {
    s = icosphere(subdiv);
    SPHERE_CACHE.set(subdiv, s);
  }
  return s;
}

export function buildLump(shape, geomOpts, out) {
  const { radiusScale, tess } = geomOpts;
  const idxStart = out.indices.length;
  const vertexStart = out.vWrite;
  let subdiv = shape.subdiv;
  if (subdiv === undefined || subdiv === null) {
    const r = (shape.radii[0] + shape.radii[1] + shape.radii[2]) / 3;
    subdiv = r * tess.scale * tess.budget > 0.05 ? 2 : 1;
  }
  const s = sphere(subdiv);
  // Capture the write range ONCE. Re-reading `out.positions.length` while
  // appending made this loop's bound grow with every vertex it added, so the
  // candidate weights were written hundreds of vertices past the shape.
  const base = out.positions.length / 3;
  const [cx, cy, cz] = shape.centre;
  const rx = shape.radii[0] * radiusScale;
  const ry = shape.radii[1] * radiusScale;
  const rz = shape.radii[2] * radiusScale;
  for (const n of s.dirs) {
    const f = shapeFactor(n[0], n[1], n[2], shape.round);
    const px = cx + n[0] * rx * f;
    const py = cy + n[1] * ry * f;
    const pz = cz + n[2] * rz * f;
    out.positions.push(px, py, pz);
    // Surface normal by central differences of the implicit field, evaluated at
    // the point we just emitted, in the same centred frame the field expects.
    const h = Math.max(1e-4, Math.min(rx, ry, rz) * 0.02);
    const lx = px - cx, ly = py - cy, lz = pz - cz;
    const gx = lumpField(shape, lx + h, ly, lz) - lumpField(shape, lx - h, ly, lz);
    const gy = lumpField(shape, lx, ly + h, lz) - lumpField(shape, lx, ly - h, lz);
    const gz = lumpField(shape, lx, ly, lz + h) - lumpField(shape, lx, ly, lz - h);
    const gl = Math.hypot(gx, gy, gz) || 1;
    out.smoothNormals.push(gx / gl, gy / gl, gz / gl);
    out.partIds.push(shape.partId);
    const l = Math.hypot(n[0], n[1], n[2]) || 1;
    out.uv.push(0.5 + n[0] / (2 * l), 0.5 + n[1] / (2 * l));
  }
  const end = out.positions.length / 3;
  const count = end - base;
  for (let i = 0; i < s.faces.length; i++) {
    const t = s.faces[i];
    out.indices.push(base + t[0], base + t[1], base + t[2]);
  }
  fixShapeWinding(out, idxStart);

  // Weights. A lump either borrows the tube it articulates with (so a joint ball
  // moves WITH the blended tube rather than tearing off it) or is rigid to its own
  // bone. `curVertex`/`vertexStart` are threaded through because the write index
  // must be GLOBAL while the loop counter inside a shape is local.
  let borrowed = null;
  if (shape.anchor) borrowed = pickSkin(shape.anchor, out.positions, base, end);
  const bone = shape.bones.length ? shape.bones[0] : 0;
  for (let i = 0; i < count; i++) {
    const vi = vertexStart + i;
    if (borrowed) {
      for (let q = 0; q < 4; q++) {
        const b = borrowed[q];
        out.bi[vi * 4 + q] = b ? b[0] : 0;
        out.bw[vi * 4 + q] = b ? b[1] : 0;
      }
    } else {
      out.bi[vi * 4] = bone; out.bw[vi * 4] = 1;
      out.bi[vi * 4 + 1] = 0; out.bw[vi * 4 + 1] = 0;
      out.bi[vi * 4 + 2] = 0; out.bw[vi * 4 + 2] = 0;
      out.bi[vi * 4 + 3] = 0; out.bw[vi * 4 + 3] = 0;
    }
  }
  out.vWrite = end;
  if (shape.bones.length) {
    out.boneCount = Math.max(out.boneCount, ...shape.bones.map((b) => b + 1));
  }
}

// ------------------------------------------------------- assembly + skin ---

// Vertex count is unknown up front, and the weight arrays are indexed by GLOBAL
// vertex index — so they are pre-sized to a generous bound and `vWrite` is the
// explicit cursor. Doing this with plain sparse arrays (writing at arbitrary
// indices and reading .length later) is how the weights got silently corrupted:
// a local index used as a global one made each shape overwrite its predecessors,
// and every symptom of that was a joint tearing apart under animation.
const MAX_VERTS = 400000;

export function createMeshBuffers() {
  return {
    positions: [], smoothNormals: [], partIds: [], uv: [],
    indices: [], boneCount: 0,
    bi: new Uint16Array(MAX_VERTS * 4),
    bw: new Float32Array(MAX_VERTS * 4),
    vWrite: 0,
  };
}

export function generate(plan, opts = {}) {
  const geomOpts = {
    radiusScale: opts.radiusScale ?? 1,
    jitter: opts.jitter ?? false,
    tess: opts.tess || tessellationFor(plan, opts.budget ?? 1),
  };
  const out = createMeshBuffers();
  // Clear the weight buffers before use. They are pre-sized typed arrays that
  // live in a scratch object, and `generate()` is called once per creature, so
  // anything a shape does not explicitly write keeps the PREVIOUS creature's
  // values — which showed up as one hexapod leg skinned to the biped's arm.
  out.bi.fill(0, 0, out.bi.length);
  out.bw.fill(0, 0, out.bw.length);
  out.vWrite = 0;
  const partNames = Object.keys(plan.parts);
  for (const name of partNames) {
    const p = plan.parts[name];
    const pid = p.index;
    // Tubes first, then their lumps. A lump that sits on a joint of a tube
    // borrows that tube's weights (see buildLump), so the tube must already be
    // built. Multi-bone tubes win the claim on a shared joint.
    const tubes = p.shapes.filter((s) => s.type === 'tube')
      .sort((a, b) => b.bones.length - a.bones.length);
    for (const s of p.shapes) if (s.type !== 'tube') s.partId = pid;
    for (const s of tubes) {
      s.partId = pid;
      buildTube(s, geomOpts, out);
    }
    // A joint lump borrows the weights of the tube it belongs to. The match must
    // be EXACT (every bone of the lump is a bone of that tube) and the widest
    // tube wins: matching on "shares any bone" let a right-side knee ball anchor
    // to the left-side leg tube, which silently re-weighted it to the wrong leg.
    for (const lump of p.shapes) {
      if (lump.type === 'tube' || lump.anchor || !lump.bones.length) continue;
      let best = null;
      for (const b of tubes) {
        const bones = new Set(b.bones);
        if (!lump.bones.every((bi) => bones.has(bi))) continue;
        if (!best || b.bones.length > best.bones.length) best = b;
      }
      if (best) lump.anchor = best._skin;
    }
    for (const s of p.shapes) {
      if (s.type === 'tube') continue;
      buildLump(s, geomOpts, out);
    }
  }
  // Per-shape smoothing pass on the smooth normals (area+angle weighted
  // accumulation), which is what turns the tessellated tube into a continuously
  // shaded surface across the joint rings.
  accumulateNormals(out);
  return packMesh(plan, out, opts);
}

// Accumulate per-face normals into the per-vertex smooth normals. Angle
// weighting keeps the silhouette of low-poly rings even.
function accumulateNormals(out) {
  const pos = out.positions;
  const idx = out.indices;
  const acc = new Float32Array(pos.length);
  const accW = new Float32Array(pos.length / 3);
  for (let i = 0; i < idx.length; i += 3) {
    const a = idx[i] * 3, b = idx[i + 1] * 3, c = idx[i + 2] * 3;
    const e1x = pos[b] - pos[a], e1y = pos[b + 1] - pos[a + 1], e1z = pos[b + 2] - pos[a + 2];
    const e2x = pos[c] - pos[a], e2y = pos[c + 1] - pos[a + 1], e2z = pos[c + 2] - pos[a + 2];
    // Counter-clockwise seen from outside => the outward geometric normal is
    // e1 x e2. Verified against a ground-truth closed cylinder, not by eye.
    let nx = e1y * e2z - e1z * e2y;
    let ny = e1z * e2x - e1x * e2z;
    let nz = e1x * e2y - e1y * e2x;
    const len = Math.hypot(nx, ny, nz);
    const area = len / 2;
    if (area < 1e-12) continue;
    nx /= len; ny /= len; nz /= len;
    for (const v of [a, b, c]) {
      acc[v] += nx; acc[v + 1] += ny; acc[v + 2] += nz;
      accW[v / 3] += area;
    }
  }
  for (let v = 0; v < accW.length; v++) {
    if (accW[v] <= 1e-12) continue;
    const l = Math.hypot(acc[v * 3], acc[v * 3 + 1], acc[v * 3 + 2]) || 1;
    out.smoothNormals[v * 3] = acc[v * 3] / l;
    out.smoothNormals[v * 3 + 1] = acc[v * 3 + 1] / l;
    out.smoothNormals[v * 3 + 2] = acc[v * 3 + 2] / l;
  }
}

// Emit flat (per-face) normals alongside the smooth ones so the debug view can
// flip between "seam blended" and "raw primitives" on the same geometry — that
// A/B is the evidence that the blend is doing real work.
function buildFlatNormals(out) {
  const pos = out.positions;
  const idx = out.indices;
  const flat = new Float32Array(pos.length);
  for (let i = 0; i < idx.length; i += 3) {
    const a = idx[i] * 3, b = idx[i + 1] * 3, c = idx[i + 2] * 3;
    const e1x = pos[b] - pos[a], e1y = pos[b + 1] - pos[a + 1], e1z = pos[b + 2] - pos[a + 2];
    const e2x = pos[c] - pos[a], e2y = pos[c + 1] - pos[a + 1], e2z = pos[c + 2] - pos[a + 2];
    let nx = e1y * e2z - e1z * e2y;
    let ny = e1z * e2x - e1x * e2z;
    let nz = e1x * e2y - e1y * e2x;
    const l = Math.hypot(nx, ny, nz) || 1;
    nx /= l; ny /= l; nz /= l;
    for (const v of [a, b, c]) { flat[v] = nx; flat[v + 1] = ny; flat[v + 2] = nz; }
  }
  return flat;
}

export function packMesh(plan, out, opts = {}) {
  const vertexCount = out.positions.length / 3;
  const positions = new Float32Array(out.positions);
  const normals = new Float32Array(out.smoothNormals);
  const flat = buildFlatNormals(out);
  // One byte per bone index is enough for the rigs this generates and keeps the
  // attribute small; weights stay float because they are used in the shader sum.
  const bi = new Uint8Array(Math.max(4, vertexCount * 4));
  const bw = new Float32Array(Math.max(4, vertexCount * 4));
  for (let i = 0; i < vertexCount * 4; i++) bi[i] = out.bi[i];
  bw.set(out.bw.subarray(0, vertexCount * 4));
  // Normalise weights defensively: the shader divides by the weight sum, but a
  // generator bug should show up as a smooth surface, not as an explosion.
  for (let v = 0; v < vertexCount; v++) {
    const s = bw[v * 4] + bw[v * 4 + 1] + bw[v * 4 + 2] + bw[v * 4 + 3];
    if (s <= 1e-6) { bw[v * 4] = 1; } else {
      bw[v * 4] /= s; bw[v * 4 + 1] /= s; bw[v * 4 + 2] /= s; bw[v * 4 + 3] /= s;
    }
  }
  const indices = vertexCount > 65535 ? new Uint32Array(out.indices) : new Uint16Array(out.indices);
  const mesh = {
    plan,
    positions,
    normals,
    flatNormals: flat,
    partIds: new Uint8Array(out.partIds),
    uv: new Float32Array(out.uv),
    bi,
    bw,
    indices,
    vertexCount,
    triangleCount: indices.length / 3,
    boneCount: plan.joints.length,
    parts: Object.keys(plan.parts),
  };
  // Orientation report. `outwardSum` = Σ dot(faceCentre, outwardNormal) = 3·V and
  // must be POSITIVE on a correctly wound closed surface; `volume` is the
  // origin-relative signed volume, kept because it is the conventional number.
  // Each shape already fixed its own winding (see fixShapeWinding), so there is
  // nothing to flip here — flipping globally would have masked a per-shape flip.
  mesh.outwardSum = outwardSum(mesh);
  mesh.signedVolume = signedVolume(mesh);
  mesh.windingFlips = out.windingFlips || 0;
  return mesh;
}

// Σ dot(faceCentre, outwardNormal). Positive ⇒ every normal faces outward.
export function outwardSum(mesh) {
  const p = mesh.positions, idx = mesh.indices;
  let s = 0;
  for (let i = 0; i < idx.length; i += 3) {
    const a = idx[i] * 3, b = idx[i + 1] * 3, c = idx[i + 2] * 3;
    const e1x = p[b] - p[a], e1y = p[b + 1] - p[a + 1], e1z = p[b + 2] - p[a + 2];
    const e2x = p[c] - p[a], e2y = p[c + 1] - p[a + 1], e2z = p[c + 2] - p[a + 2];
    const nx = e1y * e2z - e1z * e2y;
    const ny = e1z * e2x - e1x * e2z;
    const nz = e1x * e2y - e1y * e2x;
    const cx = (p[a] + p[b] + p[c]) / 3;
    const cy = (p[a + 1] + p[b + 1] + p[c + 1]) / 3;
    const cz = (p[a + 2] + p[b + 2] + p[c + 2]) / 3;
    s += cx * nx + cy * ny + cz * nz;
  }
  return s;
}

export function signedVolume(mesh) {
  const p = mesh.positions, idx = mesh.indices;
  let v = 0;
  for (let i = 0; i < idx.length; i += 3) {
    const a = idx[i] * 3, b = idx[i + 1] * 3, c = idx[i + 2] * 3;
    v += (p[a] * (p[b + 1] * p[c + 2] - p[b + 2] * p[c + 1]) -
      p[a + 1] * (p[b] * p[c + 2] - p[b + 2] * p[c]) +
      p[a + 2] * (p[b] * p[c + 1] - p[b + 1] * p[c])) / 6;
  }
  return v;
}

// Bind-pose inverse matrices; the shader multiplies animation matrices by these.
export function restInverses(plan) {
  const inv = plan.joints.map((b) => m4invert(m4(), m4()));
  return inv;
}

// ------------------------------------------------------------- digest -----

// FNV-1a over the quantised geometry: the determinism gate compares two runs'
// digests. Quantised so a last-bit float difference is not reported as a
// different character, but any real change is.
export function digest(mesh) {
  let h = 0x811c9dc5;
  const mix = (x) => {
    h ^= x & 0xff; h = Math.imul(h, 0x01000193);
  };
  const q = (v) => Math.round(v * 100000) | 0;
  for (let i = 0; i < mesh.positions.length; i++) {
    const v = q(mesh.positions[i]);
    mix(v); mix(v >> 8); mix(v >> 16); mix(v >> 24);
  }
  for (let i = 0; i < mesh.indices.length; i++) {
    const v = mesh.indices[i];
    mix(v); mix(v >> 8);
  }
  for (let i = 0; i < mesh.bw.length; i++) mix(Math.round(mesh.bw[i] * 255));
  for (let i = 0; i < mesh.bi.length; i++) mix(mesh.bi[i]);
  return (h >>> 0).toString(16).padStart(8, '0');
}
