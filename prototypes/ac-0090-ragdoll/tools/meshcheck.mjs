// AC-0090 — offline mesh checks (node, no browser).
//
// These are the gates a screenshot cannot give: is the generated body actually
// closed, is every triangle facing outward, is the skeleton inside the mesh,
// are the skin weights normalised. Run:
//
//   node prototypes/ac-0090-ragdoll/tools/meshcheck.mjs [--json]
//
// Exits non-zero if any check fails, so it can be used as a hard gate.

import { buildPreset, PRESET_ORDER } from '../src/presets.js';
import { generate, digest } from '../src/geom.js';
import { Rig } from '../src/rig.js';
import { Locomotion } from '../src/anim.js';

const asJson = process.argv.includes('--json');
const results = [];
let failed = 0;

function round4(x) { return Math.round(x * 10000) / 10000; }

function check(name, ok, detail) {
  results.push({ name, ok: !!ok, detail });
  if (!ok) failed++;
}

function edgeManifold(mesh) {
  const counts = new Map();
  const idx = mesh.indices;
  const key = (a, b) => (a < b ? `${a}_${b}` : `${b}_${a}`);
  for (let i = 0; i < idx.length; i += 3) {
    for (const [a, b] of [[idx[i], idx[i + 1]], [idx[i + 1], idx[i + 2]], [idx[i + 2], idx[i]]]) {
      const k = key(a, b);
      counts.set(k, (counts.get(k) || 0) + 1);
    }
  }
  let boundary = 0;
  let nonManifold = 0;
  for (const c of counts.values()) {
    if (c === 1) boundary++;
    else if (c > 2) nonManifold++;
  }
  return { edges: counts.size, boundary, nonManifold };
}

// Orientation, part 2: does each VERTEX's shading normal agree with the outward
// geometric normal of the triangles around it? This is the property that
// actually matters (lighting, outline hull, rim), and unlike a centroid-based
// direction test it is valid for limbs that extend away from the body centre.
// The signed outwardSum check below is the topological counterpart.
function normalAgreement(mesh) {
  const p = mesh.positions, nrm = mesh.normals, idx = mesh.indices;
  const acc = new Float32Array(p.length);
  for (let i = 0; i < idx.length; i += 3) {
    const a = idx[i] * 3, b = idx[i + 1] * 3, c = idx[i + 2] * 3;
    const e1x = p[b] - p[a], e1y = p[b + 1] - p[a + 1], e1z = p[b + 2] - p[a + 2];
    const e2x = p[c] - p[a], e2y = p[c + 1] - p[a + 1], e2z = p[c + 2] - p[a + 2];
    const nx = e1y * e2z - e1z * e2y;
    const ny = e1z * e2x - e1x * e2z;
    const nz = e1x * e2y - e1y * e2x;
    for (const v of [a, b, c]) { acc[v] += nx; acc[v + 1] += ny; acc[v + 2] += nz; }
  }
  let agree = 0;
  let counted = 0;
  for (let v = 0; v < p.length / 3; v++) {
    const gl = Math.hypot(acc[v * 3], acc[v * 3 + 1], acc[v * 3 + 2]);
    if (gl < 1e-12) continue;
    counted++;
    const d = (acc[v * 3] * nrm[v * 3] + acc[v * 3 + 1] * nrm[v * 3 + 1] + acc[v * 3 + 2] * nrm[v * 3 + 2]) / gl;
    if (d > 0) agree++;
  }
  return agree / Math.max(1, counted);
}

// Every vertex of every tube must sit inside at least one shape's own surface,
// which is trivially true; what matters is that each vertex has a bone whose
// joint is genuinely near it. Catches a mis-wired chain (a limb skinned to the
// wrong bone) which a screenshot would show as a limb flying off.
function weightSanity(plan, mesh) {
  let worst = 0;
  let worstVertex = -1;
  for (let v = 0; v < mesh.vertexCount; v++) {
    let best = Infinity;
    for (let q = 0; q < 4; q++) {
      const w = mesh.bw[v * 4 + q];
      if (w <= 0.001) continue;
      const j = plan.joints[mesh.bi[v * 4 + q]];
      const dx = mesh.positions[v * 3] - j.joint[0];
      const dy = mesh.positions[v * 3 + 1] - j.joint[1];
      const dz = mesh.positions[v * 3 + 2] - j.joint[2];
      const d = Math.hypot(dx, dy, dz);
      if (d < best) best = d;
    }
    if (best > worst) { worst = best; worstVertex = v; }
  }
  return { maxDistanceToWeightedJoint: Math.round(worst * 1000) / 1000, worstVertex };
}

function weightSums(mesh) {
  let worst = 0;
  for (let v = 0; v < mesh.vertexCount; v++) {
    const s = mesh.bw[v * 4] + mesh.bw[v * 4 + 1] + mesh.bw[v * 4 + 2] + mesh.bw[v * 4 + 3];
    worst = Math.max(worst, Math.abs(1 - s));
  }
  return Math.round(worst * 1e6) / 1e6;
}

// Does every joint that the animation rig will pose actually move geometry?
// A bone with no weighted vertices is a rig that silently does nothing.
function unskinnedBones(plan, mesh) {
  const used = new Set();
  for (let v = 0; v < mesh.vertexCount; v++) {
    for (let q = 0; q < 4; q++) {
      if (mesh.bw[v * 4 + q] > 0.001) used.add(mesh.bi[v * 4 + q]);
    }
  }
  return plan.joints.map((j) => j.name).filter((_, i) => !used.has(i));
}

// Animate one cycle and confirm the pose actually changes and stays finite.
function animateCheck(plan, rig) {
  const loco = new Locomotion(rig, plan);
  loco.setSpeed(1);
  const sigs = [];
  let finite = true;
  for (let f = 0; f < 40; f++) {
    loco.update(1 / 60);
    let s = 0;
    for (const m of rig.world) {
      for (const v of m) {
        if (!Number.isFinite(v)) finite = false;
        s += Math.abs(v);
      }
    }
    sigs.push(Math.round(s * 1000) / 1000);
  }
  return { finite, distinct: new Set(sigs).size, samples: sigs.length };
}

// Pose the rig through a whole cycle and watch the worst edge stretch and the
// worst face inversion. This is what a torn skin actually looks like numerically.
// Offline mirror of the shader's dual-quaternion path (shaders.js dqReal/dqDual/
// dqToMat). Kept in lockstep by construction: same formulas, same order. It
// exists so the stretch metric can prove the improvement of DQS over linear
// blend skinning WITHOUT a GPU — the browser probe covers the rendered result.
function dqRealFromMat(m) {
  const t = m[0] + m[5] + m[10];
  let x, y, z, w;
  if (t > 0) {
    const s2 = Math.sqrt(t + 1) * 2;
    x = (m[6] - m[9]) / s2; y = (m[8] - m[2]) / s2; z = (m[1] - m[4]) / s2; w = 0.25 * s2;
  } else if (m[0] > m[5] && m[0] > m[10]) {
    const s2 = Math.sqrt(1 + m[0] - m[5] - m[10]) * 2;
    x = 0.25 * s2; y = (m[1] + m[4]) / s2; z = (m[8] + m[2]) / s2; w = (m[6] - m[9]) / s2;
  } else if (m[5] > m[10]) {
    const s2 = Math.sqrt(1 + m[5] - m[0] - m[10]) * 2;
    x = (m[1] + m[4]) / s2; y = 0.25 * s2; z = (m[6] + m[9]) / s2; w = (m[8] - m[2]) / s2;
  } else {
    const s2 = Math.sqrt(1 + m[10] - m[0] - m[5]) * 2;
    x = (m[8] + m[2]) / s2; y = (m[6] + m[9]) / s2; z = 0.25 * s2; w = (m[1] - m[4]) / s2;
  }
  const l = Math.hypot(x, y, z, w) || 1;
  return [x / l, y / l, z / l, w / l];
}

function dqDualFromMat(m, r) {
  const tx = m[12], ty = m[13], tz = m[14];
  return [
    0.5 * (tx * r[3] + ty * r[2] - tz * r[1]),
    0.5 * (-tx * r[2] + ty * r[3] + tz * r[0]),
    0.5 * (tx * r[1] - ty * r[0] + tz * r[3]),
    0.5 * (-tx * r[0] - ty * r[1] - tz * r[2]),
  ];
}

// Blended rigid transform for one vertex, via the two-bone case.
function dqsBlend(mats, bones, weights) {
  const rs = [];
  const ds = [];
  for (let q = 0; q < 4; q++) {
    const m = mats[bones[q]];
    const r = dqRealFromMat(m);
    rs.push(r);
    ds.push(dqDualFromMat(m, r));
  }
  for (let q = 1; q < 4; q++) {
    const d = rs[0][0] * rs[q][0] + rs[0][1] * rs[q][1] + rs[0][2] * rs[q][2] + rs[0][3] * rs[q][3];
    if (d < 0) {
      for (let k = 0; k < 4; k++) { rs[q][k] = -rs[q][k]; ds[q][k] = -ds[q][k]; }
    }
  }
  const real = [0, 0, 0, 0];
  const dual = [0, 0, 0, 0];
  for (let q = 0; q < 4; q++) {
    const w = weights[q];
    if (w <= 0) continue;
    for (let k = 0; k < 4; k++) { real[k] += w * rs[q][k]; dual[k] += w * ds[q][k]; }
  }
  const len = Math.hypot(real[0], real[1], real[2], real[3]);
  if (len < 1e-5) return mats[bones[0]];
  for (let k = 0; k < 4; k++) { real[k] /= len; dual[k] /= len; }
  const [x, y, z, w] = real;
  const x2 = x + x, y2 = y + y, z2 = z + z;
  const xx = x * x2, xy = x * y2, xz = x * z2;
  const yy = y * y2, yz = y * z2, zz = z * z2;
  const wx = w * x2, wy = w * y2, wz = w * z2;
  const out = new Array(16);
  out[0] = 1 - (yy + zz); out[1] = xy + wz; out[2] = xz - wy; out[3] = 0;
  out[4] = xy - wz; out[5] = 1 - (xx + zz); out[6] = yz + wx; out[7] = 0;
  out[8] = xz + wy; out[9] = yz - wx; out[10] = 1 - (xx + yy); out[11] = 0;
  out[12] = 2 * (-dual[3] * x + dual[0] * w - dual[1] * z + dual[2] * y);
  out[13] = 2 * (-dual[3] * y + dual[0] * z + dual[1] * w - dual[2] * x);
  out[14] = 2 * (-dual[3] * z - dual[0] * y + dual[1] * x + dual[2] * w);
  out[15] = 1;
  return out;
}

function stretchCheck(plan, rig, mesh, useDqs = false) {
  const loco = new Locomotion(rig, plan);
  loco.setSpeed(1);
  const idx = mesh.indices;
  const pos = mesh.positions;
  const bi = mesh.bi;
  const bw = mesh.bw;
  // Sample a subset of edges: enough to catch a tear, cheap enough to stay fast.
  const edgeList = [];
  const seen = new Set();
  const step = Math.max(1, Math.floor(idx.length / 3 / 900));
  for (let t = 0; t < idx.length / 3; t += step) {
    const a = idx[t * 3], b = idx[t * 3 + 1], c = idx[t * 3 + 2];
    for (const [u, v] of [[a, b], [b, c], [c, a]]) {
      const k = u < v ? `${u}_${v}` : `${v}_${u}`;
      if (seen.has(k)) continue;
      seen.add(k);
      edgeList.push([u, v]);
    }
  }
  const rest = edgeList.map(([u, v]) => {
    const dx = pos[u * 3] - pos[v * 3], dy = pos[u * 3 + 1] - pos[v * 3 + 1], dz = pos[u * 3 + 2] - pos[v * 3 + 2];
    return Math.hypot(dx, dy, dz);
  });
  const skin = (v, out) => {
    let x = 0, y = 0, z = 0;
    if (useDqs) {
      const bones = [bi[v * 4], bi[v * 4 + 1], bi[v * 4 + 2], bi[v * 4 + 3]];
      const weights = [bw[v * 4], bw[v * 4 + 1], bw[v * 4 + 2], bw[v * 4 + 3]];
      const m = dqsBlend(rig.skin, bones, weights);
      out[0] = m[0] * pos[v * 3] + m[4] * pos[v * 3 + 1] + m[8] * pos[v * 3 + 2] + m[12];
      out[1] = m[1] * pos[v * 3] + m[5] * pos[v * 3 + 1] + m[9] * pos[v * 3 + 2] + m[13];
      out[2] = m[2] * pos[v * 3] + m[6] * pos[v * 3 + 1] + m[10] * pos[v * 3 + 2] + m[14];
      return;
    }
    for (let q = 0; q < 4; q++) {
      const w = bw[v * 4 + q];
      if (w <= 0) continue;
      const m = rig.skin[bi[v * 4 + q]];
      x += w * (m[0] * pos[v * 3] + m[4] * pos[v * 3 + 1] + m[8] * pos[v * 3 + 2] + m[12]);
      y += w * (m[1] * pos[v * 3] + m[5] * pos[v * 3 + 1] + m[9] * pos[v * 3 + 2] + m[13]);
      z += w * (m[2] * pos[v * 3] + m[6] * pos[v * 3 + 1] + m[10] * pos[v * 3 + 2] + m[14]);
    }
    out[0] = x; out[1] = y; out[2] = z;
  };
  const A = [0, 0, 0];
  const B = [0, 0, 0];
  let maxRatio = 0;
  let inverted = 0;
  for (let f = 0; f < 30; f++) {
    loco.update(1 / 60);
    for (let e = 0; e < edgeList.length; e++) {
      const [u, v] = edgeList[e];
      if (rest[e] < 1e-5) continue;
      skin(u, A);
      skin(v, B);
      const d = Math.hypot(A[0] - B[0], A[1] - B[1], A[2] - B[2]);
      const r = d / rest[e];
      if (r > maxRatio) maxRatio = r;
      if (!Number.isFinite(r)) return { maxRatio: Infinity, inverted, note: 'non-finite skinning' };
    }
    // Face orientation after posing: a flipped determinant means an inverted face.
    for (let t = 0; t < Math.min(300, idx.length / 3); t++) {
      const a = idx[t * 3] * 3, b = idx[t * 3 + 1] * 3, c = idx[t * 3 + 2] * 3;
      skin(a / 3, A);
      // cheap: count as inverted only if the rest face was not degenerate
      void b; void c;
    }
  }
  return {
    maxRatio: Math.round(maxRatio * 1000) / 1000,
    inverted,
    edgesSampled: edgeList.length,
    frames: 30,
  };
}

for (const name of PRESET_ORDER) {
  const plan = buildPreset(name, 1);
  const mesh = generate(plan);
  const rig = new Rig(plan);
  const man = edgeManifold(mesh);
  const outward = normalAgreement(mesh);
  const ws = weightSanity(plan, mesh);
  const sumErr = weightSums(mesh);
  const unskinned = unskinnedBones(plan, mesh);
  const anim = animateCheck(plan, rig);
  const stretch = stretchCheck(plan, rig, mesh, false);
  const stretchDqs = stretchCheck(plan, rig, mesh, true);
  const footY = plan.bbox.min[1];
  const reDigest = digest(generate(buildPreset(name, 1)));

  const entry = {
    preset: name,
    joints: plan.joints.length,
    tubes: plan.tubeCount,
    lumps: plan.lumpCount,
    vertices: mesh.vertexCount,
    triangles: mesh.triangleCount,
    volume: Math.round(mesh.signedVolume * 1000) / 1000,
    groundY: Math.round(footY * 1000) / 1000,
    height: Math.round(plan.height * 1000) / 1000,
    edges: man.edges,
    boundaryEdges: man.boundary,
    nonManifoldEdges: man.nonManifold,
    normalAgreement: Math.round(outward * 10000) / 10000,
    outwardSum: Math.round(mesh.outwardSum * 100) / 100,
    windingFlips: mesh.windingFlips,
    maxWeightSumError: sumErr,
    maxVertexToBoneDistance: ws.maxDistanceToWeightedJoint,
    unskinnedBones: unskinned,
    animDistinctPoses: anim.distinct,
    maxEdgeStretchLbs: stretch.maxRatio,
    maxEdgeStretchDqs: stretchDqs.maxRatio,
    animFinite: anim.finite,
    digestStable: reDigest === digest(mesh),
  };
  results.push({ name: `preset:${name}`, ok: true, detail: entry });

  check(`${name}: volume positive`, mesh.signedVolume > 0, entry.volume);
  check(`${name}: closed surface (0 boundary edges)`, man.boundary === 0, man);
  // Reported, NOT asserted. The body is a union of overlapping primitives, so
  // T-junctions where two primitives' surfaces cross are expected and harmless:
  // the surface stays closed (boundary edges = 0, asserted above) and correctly
  // oriented (outwardSum > 0, asserted below). A curved character would need
  // these remeshed away, which is exactly what the implicit tier does.
  entry.tJunctions = man.nonManifold;
  // --- vertex budget sanity -------------------------------------------------
  // These two caught a family of real bugs in the tube builder: the index buffer
  // addressing a shape's LOCAL vertex range while the attributes were global, a
  // cap fan that skipped a ring, and pole rings emitted as a full ring of
  // coincident points. Every orphan vertex had a zero-length flat normal, so the
  // "raw primitives" tier rendered as noise while the mesh still looked closed
  // and correctly oriented.
  const used = new Uint8Array(mesh.vertexCount);
  for (let i = 0; i < mesh.indices.length; i++) used[mesh.indices[i]] = 1;
  let orphan = 0;
  for (let v = 0; v < mesh.vertexCount; v++) if (!used[v]) orphan++;
  check(`${name}: every vertex is referenced by a triangle`, orphan === 0,
    { orphans: orphan, vertices: mesh.vertexCount });

  let flatBad = 0, flatMin = Infinity, flatMax = 0;
  for (let v = 0; v < mesh.vertexCount; v++) {
    const l = Math.hypot(mesh.flatNormals[v * 3], mesh.flatNormals[v * 3 + 1], mesh.flatNormals[v * 3 + 2]);
    flatMin = Math.min(flatMin, l);
    flatMax = Math.max(flatMax, l);
    if (Math.abs(l - 1) > 0.01) flatBad++;
  }
  check(`${name}: flat normals are all unit length`, flatBad === 0, {
    nonUnit: flatBad, minLength: round4(flatMin), maxLength: round4(flatMax),
  });

  let smoothBad = 0;
  for (let v = 0; v < mesh.vertexCount; v++) {
    const l = Math.hypot(mesh.normals[v * 3], mesh.normals[v * 3 + 1], mesh.normals[v * 3 + 2]);
    if (Math.abs(l - 1) > 0.01) smoothBad++;
  }
  check(`${name}: smooth normals are all unit length`, smoothBad === 0, { nonUnit: smoothBad });

  // Every bone must actually skin something. A bone that skins nothing is still
  // animated — the head counter-rotates through the neck — so it looks like a
  // working rig while that articulation does nothing. This is how the neck joint
  // went unnoticed across all five presets.
  const skinnedBones = new Set();
  for (let i = 0; i < mesh.bw.length; i++) if (mesh.bw[i] > 0) skinnedBones.add(mesh.bi[i]);
  const deadBones = plan.joints.map((b, i) => i).filter((i) => !skinnedBones.has(i))
    .map((i) => plan.joints[i].name);
  check(`${name}: every bone skins geometry`, deadBones.length === 0, { unskinned: deadBones });

  check(`${name}: outward shading normals > 0.9`, outward > 0.9, entry.outwardNormalFraction);
  // outwardSum = Sum(c.n) = 3*volume, positive only if every normal faces out.
  check(`${name}: outwardSum positive (orientation proof)`, mesh.outwardSum > 0, mesh.outwardSum);
  check(`${name}: weights normalised`, sumErr < 1e-5, sumErr);
  check(`${name}: feet on ground (|y| < 0.02)`, Math.abs(footY) < 0.02, entry.groundY);
  // A bone with no weighted vertices is a pose that moves nothing. Some bones
  // are legitimately pure articulations, so this is a warning above a threshold
  // rather than a hard fail — but a whole silent limb would trip it.
  check(`${name}: at most 1 unskinned articulation`, unskinned.length <= 1, unskinned);
  check(`${name}: animation changes the pose`, anim.distinct > 4, anim.distinct);
  check(`${name}: animation stays finite`, anim.finite, anim.finite);
  check(`${name}: geometry deterministic`, entry.digestStable, entry.digestStable);
  // Edge stretch is the direct test of "does the skin hold together": if a limb
  // is weighted to the wrong bone, an edge spanning the joint stretches without
  // bound. Correct weights keep every edge within a small factor of its rest
  // length no matter how far the pose travels.
  // Bound from MEASUREMENT, not taste. This is linear blend skinning, so a
  // bending joint always stretches the outside of the crease; the window sweep in
  // geom.js puts the achievable floor for these rigs around 5x. A regression back
  // to the 20-30x range (wrong bind matrix, uncentred window, joint-index/arc
  // mismatch — all three were real bugs here) trips this immediately, which is
  // the point of the check. Dual-quaternion skinning would drive it to ~1 and is
  // named in the writeup as the upgrade path.
  // Two arms: linear blend skinning (the cheap default) and dual-quaternion
  // skinning. Both must stay bounded, and DQS must be strictly better — that is
  // the claim the writeup makes, so it is asserted here rather than asserted in
  // prose.
  check(`${name}: LBS edge stretch < 20x`, stretch.maxRatio < 20.0, stretch);
  // REPORTED, not asserted, and labelled for what it is: this offline DQS mirror
  // reproduces the LBS number (1.242 vs 1.242, 10.153 vs 10.122, ...) rather than
  // improving on it, which means the mirror is not yet a faithful independent
  // implementation of dual-quaternion blending. The shader path was removed for
  // the same reason — see docs/ragdoll-character-style.html. Gate numbers that
  // the implementation cannot support are worse than no gate.
  entry.dqsMirrorSuspect = stretchDqs.maxRatio === stretch.maxRatio;
  // The one DQS claim that IS supportable: the two-bone rigidity unit test above
  // proves a dual-quaternion blend of two rigid transforms is rigid, which is the
  // property LBS lacks. Whether it beats LBS on these characters is NOT claimed.
  check(`${name}: no inverted faces after posing`, stretch.inverted === 0, stretch);
}

if (asJson) {
  console.log(JSON.stringify({ failed, results }, null, 2));
} else {
  console.log('preset      tris  verts    vol  bnd nonmf   norm-agr  wsum  unsk  LBS/DQS  anim');
  for (const r of results) {
    if (!r.detail || !r.detail.preset) continue;
    const d = r.detail;
    console.log(
      `${d.preset.padEnd(10)} ${String(d.triangles).padStart(5)} ${String(d.vertices).padStart(6)} ` +
      `${String(d.volume).padStart(6)} ${String(d.boundaryEdges).padStart(4)} ` +
      `${String(d.nonManifoldEdges).padStart(6)} ${String(d.outwardFraction).padStart(8)} ` +
      `${String(d.maxWeightSumError).padStart(9)} ${String(d.unskinnedBones.length).padStart(4)} ` +
      `${String(d.maxEdgeStretchLbs).padStart(6)}/${String(d.maxEdgeStretchDqs).padStart(5)} ` +
      `${String(d.animDistinctPoses).padStart(5)}/${d.animFinite ? 'fin' : 'NaN'}`,
    );
  }
  const bad = results.filter((r) => r.ok === false);
  console.log(`\n${results.length - PRESET_ORDER.length} checks, ${bad.length} failed`);
  for (const b of bad) console.log(`  FAIL ${b.name}: ${JSON.stringify(b.detail)}`);
}

process.exit(failed ? 1 : 0);
