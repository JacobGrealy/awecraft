// AC-0090 — seeded, deterministic noise. Every procedural decision in the
// generator (jitter, tints, radii wibble) goes through here so that a
// (preset, seed) pair reproduces byte-identical geometry. Nothing in the
// prototype may call Math.random().

export function xmur3(str) {
  let h = 1779033703 ^ str.length;
  for (let i = 0; i < str.length; i++) {
    h = Math.imul(h ^ str.charCodeAt(i), 3432918353);
    h = (h << 13) | (h >>> 19);
  }
  return function () {
    h = Math.imul(h ^ (h >>> 16), 2246822507);
    h = Math.imul(h ^ (h >>> 13), 3266489909);
    return (h ^= h >>> 16) >>> 0;
  };
}

export function mulberry32(a) {
  return function () {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export class Rng {
  constructor(seed) {
    this.seed = String(seed);
    this._f = mulberry32(xmur3(this.seed)());
  }
  // [0,1)
  next() {
    return this._f();
  }
  // [lo,hi)
  range(lo, hi) {
    return lo + (hi - lo) * this._f();
  }
  // [-a,+a)
  sym(a) {
    return (this._f() * 2 - 1) * a;
  }
  // integer in [lo,hi]
  int(lo, hi) {
    return lo + Math.floor(this._f() * (hi - lo + 1));
  }
  pick(arr) {
    return arr[Math.floor(this._f() * arr.length) % arr.length];
  }
  // 1 with probability p, else 0 — used for optional features (horns, ears).
  chance(p) {
    return this._f() < p;
  }
}
