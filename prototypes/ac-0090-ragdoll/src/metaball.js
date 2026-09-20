// AC-0090 — tier 3: the same shapes as ONE implicit surface.
//
// The tube tier blends joints by interpolating bone weights and normals; this
// tier removes the problem instead. Every primitive becomes a distance field,
// the fields are combined with a SMOOTH MINIMUM (so intersections melt instead
// of creasing), and the result is polygonised with surface nets. The output has
// no separate surfaces left — nothing to seam, no normal discontinuity at a
// joint, and no double-drawn geometry buried inside the body.
//
// Cost is paid at BAKE time on the CPU: the runtime still sees one mesh. That
// trade is the whole reason the mobile default stays on the tube tier, and the
// numbers for it are in the results page rather than asserted here.

import { curveSamples } from './geom.js';

// ------------------------------------------------------------- fields -----

// A capsule chain sampled from the tube's own curve and radius profile — the
// SAME curve the mesh tier uses, so the two tiers are comparable rather than
// two subtly different creatures.
function tubeField(shape, segmentsPerSpan) {
  const n = Math.max(4, (shape.points.length - 1) * segmentsPerSpan);
  const samples = curveSamples(shape.points, shape.radii, n);
  return {
    kind: 'capsule',
    pts: samples.pts,
    radii: samples.radii,
    blend: (shape.blendRadius ?? 0.5) * Math.min(...shape.radii),
    bbox: bboxOf(samples.pts, Math.max(...samples.radii) * 1.8),
  };
}

// Ellipsoid / rounded box. The superellipsoid is approximated by an ellipsoid
// distance with the `round` dial shrinking the effective radii box-wise; the
// smooth-min absorbs the approximation error, which is why this is fine for a
// blob union but would not be for a hard-edged shape.
function lumpField(shape) {
  const r = shape.radii;
  return {
    kind: 'ellipsoid',
    c: shape.centre,
    r,
    round: shape.round ?? 1,
    blend: (shape.blendRadius ?? 0.3) * Math.min(r[0], r[1], r[2]),
    bbox: {
      min: [shape.centre[0] - r[0], shape.centre[1] - r[1], shape.centre[2] - r[2]],
      max: [shape.centre[0] + r[0], shape.centre[1] + r[1], shape.centre[2] + r[2]],
    },
  };
}

function bboxOf(pts, pad) {
  const min = [Infinity, Infinity, Infinity];
  const max = [-Infinity, -Infinity, -Infinity];
  for (const p of pts) {
    for (let i = 0; i < 3; i++) {
      if (p[i] - pad < min[i]) min[i] = p[i] - pad;
      if (p[i] + pad > max[i]) max[i] = p[i] + pad;
    }
  }
  return { min, max };
}

// --------------------------------------------------------------- field ----

// Polynomial smooth minimum: exact min outside the blend band, quadratic inside.
function smin(a, b, k) {
  if (k <= 1e-6) return a < b ? a : b;
  const h = Math.max(0, Math.min(1, 0.5 + 0.5 * (b - a) / k));
  return b * (1 - h) + a * h - k * h * (1 - h);
}

function segDist(px, py, pz, a, b, out) {
  const abx = b[0] - a[0], aby = b[1] - a[1], abz = b[2] - a[2];
  const apx = px - a[0], apy = py - a[1], apz = pz - a[2];
  const denom = abx * abx + aby * aby + abz * abz;
  let t = denom > 1e-12 ? (apx * abx + apy * aby + apz * abz) / denom : 0;
  t = t < 0 ? 0 : t > 1 ? 1 : t;
  const dx = apx - abx * t, dy = apy - aby * t, dz = apz - abz * t;
  out[0] = Math.hypot(dx, dy, dz);
  out[1] = t;
  return out;
}

const _sd = [0, 0];

// Signed distance to one primitive. Capsules walk their sampled centreline once
// and interpolate the radius at the parameter of the closest segment.
function primDistance(p, x, y, z) {
  if (p.kind === 'ellipsoid') {
    const dx = (x - p.c[0]) / p.r[0];
    const dy = (y - p.c[1]) / p.r[1];
    const dz = (z - p.c[2]) / p.r[2];
    return (Math.hypot(dx, dy, dz) - 1) * Math.min(p.r[0], Math.min(p.r[1], p.r[2]));
  }
  const n = p.pts.length;
  let best = Infinity;
  let bestT = 0;
  for (let s = 0; s < n - 1; s++) {
    segDist(x, y, z, p.pts[s], p.pts[s + 1], _sd);
    if (_sd[0] < best) {
      best = _sd[0];
      bestT = (s + _sd[1]) / (n - 1);
    }
  }
  const ri = Math.max(0, Math.min(n - 1, bestT * (n - 1)));
  const i0 = Math.min(n - 1, Math.floor(ri));
  const i1 = Math.min(n - 1, i0 + 1);
  const f = ri - i0;
  const r = p.radii[i0] * (1 - f) + p.radii[i1] * f;
  return best - r;
}

// The union, evaluated against a candidate list (usually the bucket's contents).
function fieldUnion(prims, list, x, y, z, emptyValue) {
  if (!list || !list.length) return emptyValue;
  let d = primDistance(prims[list[0]], x, y, z);
  for (let a = 1; a < list.length; a++) {
    const p = prims[list[a]];
    d = smin(d, primDistance(p, x, y, z), p.blend);
  }
  return d;
}

// ------------------------------------------------------------ bucketing ---

// A uniform bucket grid over the primitives, so a field query walks only the
// handful of primitives that can matter. Without it the bake is O(primitives)
// per sample and the tier takes seconds rather than milliseconds.
function bucketize(prims, min, max, divisions) {
  const size = [max[0] - min[0], max[1] - min[1], max[2] - min[2]];
  const cs = Math.max(size[0], size[1], size[2]) / Math.max(1, divisions);
  const dims = size.map((s) => Math.max(1, Math.floor(s / cs) + 1));
  const bins = new Array(dims[0] * dims[1] * dims[2]);
  const cell = (v, d) => Math.max(0, Math.min(d - 1, Math.floor((v - min[d]) / cs)));
  prims.forEach((p, pi) => {
    const lo = [cell(p.bbox.min[0], 0), cell(p.bbox.min[1], 1), cell(p.bbox.min[2], 2)];
    const hi = [cell(p.bbox.max[0], 0), cell(p.bbox.max[1], 1), cell(p.bbox.max[2], 2)];
    for (let i = lo[0]; i <= hi[0]; i++) {
      for (let j = lo[1]; j <= hi[1]; j++) {
        for (let k = lo[2]; k <= hi[2]; k++) {
          const id = i + dims[0] * (j + dims[1] * k);
          (bins[id] || (bins[id] = [])).push(pi);
        }
      }
    }
  });
  return {
    dims,
    cs,
    bins,
    listAt(x, y, z) {
      const i = cell(x, 0), j = cell(y, 1), k = cell(z, 2);
      return bins[i + dims[0] * (j + dims[1] * k)] || null;
    },
  };
}

// ------------------------------------------------------------- remesh -----

export function remeshPlan(plan, opts = {}) {
  const resolution = opts.resolution || 42;
  const segmentsPerSpan = opts.segmentsPerSpan || 7;
  const prims = [];
  for (const s of plan.shapes) {
    prims.push(s.type === 'tube' ? tubeField(s, segmentsPerSpan) : lumpField(s));
  }
  if (!prims.length) return null;

  const maxBlend = prims.reduce((a, p) => Math.max(a, p.blend), 0);
  let min = [Infinity, Infinity, Infinity];
  let max = [-Infinity, -Infinity, -Infinity];
  for (const p of prims) {
    for (let i = 0; i < 3; i++) {
      min[i] = Math.min(min[i], p.bbox.min[i]);
      max[i] = Math.max(max[i], p.bbox.max[i]);
    }
  }
  const size = [max[0] - min[0], max[1] - min[1], max[2] - min[2]];
  const cell = Math.max(size[0], size[1], size[2]) / resolution;
  const dims = size.map((s) => Math.max(2, Math.ceil(s / cell) + 1));
  const [nx, ny, nz] = dims;
  const ox = min[0], oy = min[1], oz = min[2];
  const interior = Math.min(nx, Math.min(ny, nz));
  const buckets = bucketize(prims, min, max, interior);
  const outside = cell * 1.5;

  // Sample the field on the lattice.
  const field = new Float32Array(nx * ny * nz);
  const gidx = (i, j, k) => i + nx * (j + ny * k);
  for (let k = 0; k < nz; k++) {
    const z = oz + k * cell;
    for (let j = 0; j < ny; j++) {
      const y = oy + j * cell;
      for (let i = 0; i < nx; i++) {
        const x = ox + i * cell;
        field[gidx(i, j, k)] = fieldUnion(prims, buckets.listAt(x, y, z), x, y, z, outside);
      }
    }
  }

  const sample = (x, y, z) => fieldUnion(prims, buckets.listAt(x, y, z), x, y, z, outside);
  const gradient = (x, y, z, out) => {
    const h = cell * 0.5;
    const gx = sample(x + h, y, z) - sample(x - h, y, z);
    const gy = sample(x, y + h, z) - sample(x, y - h, z);
    const gz = sample(x, y, z + h) - sample(x, y, z - h);
    const l = Math.hypot(gx, gy, gz);
    if (l < 1e-9) { out[0] = 0; out[1] = 1; out[2] = 0; return out; }
    out[0] = gx / l; out[1] = gy / l; out[2] = gz / l;
    return out;
  };

  // Local signed distance used for the projection, clamped to the bucket's
  // contents plus the cell fallback so it can never run away.
  const localDist = (x, y, z) => {
    const d = sample(x, y, z);
    return Number.isFinite(d) ? d : outside;
  };

  const positions = [];
  const normals = [];
  const cellVert = new Int32Array((nx - 1) * (ny - 1) * (nz - 1)).fill(-1);
  const cidx = (i, j, k) => i + (nx - 1) * (j + (ny - 1) * k);
  const at = (i, j, k) => field[gidx(i, j, k)];
  const EDGES = [
    [0, 1], [2, 3], [4, 5], [6, 7],
    [0, 2], [1, 3], [4, 6], [5, 7],
    [0, 4], [1, 5], [2, 6], [3, 7],
  ];
  const corner = (c, i, j, k) => [
    ox + (i + (c & 1)) * cell,
    oy + (j + ((c >> 1) & 1)) * cell,
    oz + (k + ((c >> 2) & 1)) * cell,
  ];
  const g = [0, 1, 0];

  for (let k = 0; k < nz - 1; k++) {
    for (let j = 0; j < ny - 1; j++) {
      for (let i = 0; i < nx - 1; i++) {
        const v = [
          at(i, j, k), at(i + 1, j, k), at(i, j + 1, k), at(i + 1, j + 1, k),
          at(i, j, k + 1), at(i + 1, j, k + 1), at(i, j + 1, k + 1), at(i + 1, j + 1, k + 1),
        ];
        let neg = 0;
        for (let q = 0; q < 8; q++) if (v[q] < 0) neg++;
        if (neg === 0 || neg === 8) continue;

        let sx = 0, sy = 0, sz = 0, cnt = 0;
        for (const [a, b] of EDGES) {
          const va = v[a], vb = v[b];
          if ((va < 0) === (vb < 0)) continue;
          const t = va / (va - vb);
          const ea = corner(a, i, j, k);
          const eb = corner(b, i, j, k);
          sx += ea[0] + (eb[0] - ea[0]) * t;
          sy += ea[1] + (eb[1] - ea[1]) * t;
          sz += ea[2] + (eb[2] - ea[2]) * t;
          cnt++;
        }
        if (!cnt) continue;
        let x = sx / cnt, y = sy / cnt, z = sz / cnt;

        // Project onto the true surface: two damped Newton steps along the
        // gradient. This is what stops surface nets reading as blocks.
        const cx = ox + (i + 0.5) * cell;
        const cy = oy + (j + 0.5) * cell;
        const cz = oz + (k + 0.5) * cell;
        for (let it = 0; it < 2; it++) {
          const d = localDist(x, y, z);
          gradient(x, y, z, g);
          const nx2 = x - g[0] * d;
          const ny2 = y - g[1] * d;
          const nz2 = z - g[2] * d;
          // Keep the vertex inside its own cell: surface nets' connectivity
          // assumes one vertex per cell, and a runaway vertex tears the mesh.
          const half = cell * 0.5;
          x = Math.max(cx - half, Math.min(cx + half, nx2));
          y = Math.max(cy - half, Math.min(cy + half, ny2));
          z = Math.max(cz - half, Math.min(cz + half, nz2));
        }

        cellVert[cidx(i, j, k)] = positions.length / 3;
        positions.push(x, y, z);
        gradient(x, y, z, g);
        normals.push(g[0], g[1], g[2]);
      }
    }
  }

  // Quads: each sign-changing lattice edge joins the four cells around it.
  const indices = [];
  const quad = (a, b, c, d) => {
    if (a < 0 || b < 0 || c < 0 || d < 0) return;
    indices.push(a, b, c, a, c, d);
  };
  for (let k = 0; k < nz; k++) {
    for (let j = 0; j < ny; j++) {
      for (let i = 0; i < nx; i++) {
        const f = at(i, j, k);
        if (i + 1 < nx && j > 0 && k > 0 && (f < 0) !== (at(i + 1, j, k) < 0)) {
          quad(cellVert[cidx(i, j - 1, k - 1)], cellVert[cidx(i, j, k - 1)],
            cellVert[cidx(i, j, k)], cellVert[cidx(i, j - 1, k)]);
        }
        if (j + 1 < ny && i > 0 && k > 0 && (f < 0) !== (at(i, j + 1, k) < 0)) {
          quad(cellVert[cidx(i - 1, j, k - 1)], cellVert[cidx(i, j, k - 1)],
            cellVert[cidx(i, j, k)], cellVert[cidx(i - 1, j, k)]);
        }
        if (k + 1 < nz && i > 0 && j > 0 && (f < 0) !== (at(i, j, k + 1) < 0)) {
          quad(cellVert[cidx(i - 1, j - 1, k)], cellVert[cidx(i, j - 1, k)],
            cellVert[cidx(i, j, k)], cellVert[cidx(i - 1, j, k)]);
        }
      }
    }
  }

  const attributed = transferSkin(plan, positions, normals, indices, cell);

  // Winding: surface nets' quad order depends on which side is "inside".
  let vol = 0;
  for (let i = 0; i < attributed.indices.length; i += 3) {
    const a = attributed.indices[i] * 3, b = attributed.indices[i + 1] * 3, c = attributed.indices[i + 2] * 3;
    const p = attributed.positions;
    vol += (p[a] * (p[b + 1] * p[c + 2] - p[b + 2] * p[c + 1]) -
      p[a + 1] * (p[b] * p[c + 2] - p[b + 2] * p[c]) +
      p[a + 2] * (p[b] * p[c + 1] - p[b + 1] * p[c])) / 6;
  }
  if (vol < 0) {
    for (let i = 0; i < attributed.indices.length; i += 3) {
      const t = attributed.indices[i + 1];
      attributed.indices[i + 1] = attributed.indices[i + 2];
      attributed.indices[i + 2] = t;
    }
    for (let i = 0; i < attributed.normals.length; i++) attributed.normals[i] = -attributed.normals[i];
  }

  return {
    ...attributed,
    resolution,
    cellSize: Math.round(cell * 10000) / 10000,
    gridDims: dims,
    primitives: prims.length,
    sampledPoints: nx * ny * nz,
  };
}

// Skin weights for the remeshed surface come from the nearest vertex of the
// ORIGINAL tube-tier mesh, which already carries correct seam-blended weights.
// That is why the remesh tier deforms as well as the tube tier instead of
// needing a second skinning pass.
function transferSkin(plan, positions, normals, indices, cell) {
  const n = positions.length / 3;
  const src = plan.__sourceMesh;
  const bi = new Uint16Array(n * 4);
  const bw = new Float32Array(n * 4);
  const partIds = new Uint8Array(n);

  if (!src) {
    for (let v = 0; v < n; v++) bw[v * 4] = 1;
  } else {
    const cs = cell * 1.05;
    const hash = new Map();
    const key = (i, j, k) => `${i},${j},${k}`;
    for (let v = 0; v < src.vertexCount; v++) {
      const kk = key(
        Math.floor(src.positions[v * 3] / cs),
        Math.floor(src.positions[v * 3 + 1] / cs),
        Math.floor(src.positions[v * 3 + 2] / cs),
      );
      let a = hash.get(kk);
      if (!a) { a = []; hash.set(kk, a); }
      a.push(v);
    }
    for (let v = 0; v < n; v++) {
      const x = positions[v * 3], y = positions[v * 3 + 1], z = positions[v * 3 + 2];
      const ci = Math.floor(x / cs), cj = Math.floor(y / cs), ck = Math.floor(z / cs);
      let best = -1;
      let bestD = Infinity;
      for (let di = -1; di <= 1; di++) {
        for (let dj = -1; dj <= 1; dj++) {
          for (let dk = -1; dk <= 1; dk++) {
            const a = hash.get(key(ci + di, cj + dj, ck + dk));
            if (!a) continue;
            for (const sv of a) {
              const dx = src.positions[sv * 3] - x;
              const dy = src.positions[sv * 3 + 1] - y;
              const dz = src.positions[sv * 3 + 2] - z;
              const d = dx * dx + dy * dy + dz * dz;
              if (d < bestD) { bestD = d; best = sv; }
            }
          }
        }
      }
      if (best < 0) {
        for (let sv = 0; sv < src.vertexCount; sv++) {
          const dx = src.positions[sv * 3] - x;
          const dy = src.positions[sv * 3 + 1] - y;
          const dz = src.positions[sv * 3 + 2] - z;
          const d = dx * dx + dy * dy + dz * dz;
          if (d < bestD) { bestD = d; best = sv; }
        }
      }
      partIds[v] = best >= 0 ? src.partIds[best] : 0;
      for (let q = 0; q < 4; q++) {
        bi[v * 4 + q] = best >= 0 ? src.bi[best * 4 + q] : 0;
        bw[v * 4 + q] = best >= 0 ? src.bw[best * 4 + q] : (q === 0 ? 1 : 0);
      }
    }
  }

  const w = weld(positions, normals, indices, bi, bw, partIds, cell * 0.14);
  return {
    positions: w.positions,
    normals: w.normals,
    indices: w.indices,
    bi: w.bi,
    bw: w.bw,
    partIds: w.partIds,
    welded: w.welded,
  };
}

// Surface nets emits one vertex per cell, so neighbouring cells do not share
// vertices and the surface reads as faceted. Snap coincident positions.
function weld(positions, normals, indices, bi, bw, partIds, tol) {
  const n = positions.length / 3;
  const map = new Map();
  const remap = new Int32Array(n);
  const outPos = [];
  const outNor = [];
  const outBi = [];
  const outBw = [];
  const outPart = [];
  const inv = 1 / Math.max(1e-6, tol);
  let welded = 0;
  for (let v = 0; v < n; v++) {
    const key = `${Math.round(positions[v * 3] * inv)},${Math.round(positions[v * 3 + 1] * inv)},${Math.round(positions[v * 3 + 2] * inv)}`;
    const hit = map.get(key);
    if (hit !== undefined) { remap[v] = hit; welded++; continue; }
    const idx = outPos.length / 3;
    map.set(key, idx);
    remap[v] = idx;
    outPos.push(positions[v * 3], positions[v * 3 + 1], positions[v * 3 + 2]);
    outNor.push(normals[v * 3], normals[v * 3 + 1], normals[v * 3 + 2]);
    for (let q = 0; q < 4; q++) { outBi.push(bi[v * 4 + q]); outBw.push(bw[v * 4 + q]); }
    outPart.push(partIds[v]);
  }
  const outIdx = [];
  for (let i = 0; i < indices.length; i += 3) {
    const a = remap[indices[i]], b = remap[indices[i + 1]], c = remap[indices[i + 2]];
    if (a === b || b === c || a === c) continue;
    outIdx.push(a, b, c);
  }
  let maxV = 0;
  for (const v of outIdx) if (v > maxV) maxV = v;
  return {
    positions: new Float32Array(outPos),
    normals: new Float32Array(outNor),
    indices: maxV > 65535 ? new Uint32Array(outIdx) : new Uint16Array(outIdx),
    bi: new Uint16Array(outBi),
    bw: new Float32Array(outBw),
    partIds: new Uint8Array(outPart),
    welded,
  };
}
