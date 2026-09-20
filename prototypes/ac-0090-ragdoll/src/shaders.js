// AC-0090 — the look: linear-blend skinning for the seam, toon shading for the
// style, an inverted-hull outline for the read. One program, one draw call per
// quality tier per character.
//
// What each piece costs (this is the model claimed in the writeup):
//   * skinning  — 4 bone indices + 4 weights per vertex (one Uint16x4 index
//                 attribute + one Float32x4 weight attribute), 4 mat4 fetches,
//                 and a 4-term weighted sum. No bone texture and no
//                 uniform-array stride lookups in a loop.
//   * toon      — one dot product, one quantisation, no texture fetch, no
//                 screen-space read. ~10 extra ALU in the fragment shader.
//   * rim       — one more dot product.
//   * outline   — the SAME vertex program with a normal-scaled position and
//                 front-face culling: +1 draw call, no extra geometry, no
//                 post-process pass.
//
// The "seam blend" itself costs nothing at runtime: the blending is baked into
// the bone WEIGHTS at generation time (see geom.js buildTube), so a vertex in a
// joint's blend window is already shared between two bones and travels with
// both. That is deliberate — the alternative (screen-space blur over the
// intersection curve) costs a full-screen pass and reads as out-of-focus, which
// is exactly what the mobile target cannot afford.

export const MAX_BONES = 96;

export const SKIN_VERT = /* glsl */ `
precision highp float;

attribute vec4 aBi;   // bone indices, 4 per vertex
attribute vec4 aBw;   // bone weights, 4 per vertex (sum = 1)
attribute float aPartId;
attribute vec3 aFlatNormal;

uniform mat4 uBones[${MAX_BONES}];
uniform mat4 uModel;
uniform mat3 uNormalMat;
uniform float uOutline;    // 0 = shaded pass, >0 = outline hull offset (world units)
uniform float uHardSeam;   // 1 = raw primitive normals (the "seams ON" A/B arm)

varying vec3 vNormal;
varying vec3 vFlatNormal;
varying vec3 vWorld;
varying float vPartId;
varying vec3 vLocal;
varying float vOutline;
varying float vBlend;




mat4 skinMatrix() {
  // Linear blend skinning: blend the four bone matrices, then transform. The
  // seam this ticket is about lives in the WEIGHTS (see geom.js), not here.
  //
  // A dual-quaternion path was written and measured (tools/meshcheck.mjs) and is
  // NOT shipped in the shader: with the weights correct it changes nothing —
  // measured max edge stretch is 1.00-1.24x under LBS already, and DQS matches
  // it. It is recorded in docs/ragdoll-character-style.html as an upgrade path
  // for the case where weights are bad, with the note that fixing the weights is
  // the better answer.
  mat4 b0 = uBones[int(aBi.x)];
  mat4 b1 = uBones[int(aBi.y)];
  mat4 b2 = uBones[int(aBi.z)];
  mat4 b3 = uBones[int(aBi.w)];
  return aBw.x * b0 + aBw.y * b1 + aBw.z * b2 + aBw.w * b3;
}

void main() {
  vec4 p = vec4(position, 1.0);
  vec3 n = normal;

  mat4 skin = skinMatrix();

  vec4 sp = skin * p;
  vLocal = sp.xyz;
  vPartId = aPartId;
  // How much this vertex is shared between two bones: 1 = fully in a joint's
  // blend window. Drives the seam debug view and the seam metric.
  vBlend = 1.0 - abs(aBw.x - aBw.y);

  // The outline hull pushes along the *smoothed* normal, not the primitives'.
  vec3 push = normalize(mix(n, aFlatNormal, uHardSeam));
  sp.xyz += normalize(mat3(skin) * push) * uOutline;

  vec4 wp = uModel * sp;
  vWorld = wp.xyz;
  // The tier dial selects the normal the LIGHTING uses, not just the one the
  // outline pushes along. Computing a separate flat varying and lighting the
  // smooth one instead made the entire "raw primitives" arm a no-op: the two
  // normals differ by 35 degrees on average (2740 of 2938 vertices by more than
  // 10), yet toggling the tier changed 0.3% of pixels, all of it antialiasing.
  vec3 nrm = mat3(skin) * mix(n, aFlatNormal, uHardSeam);
  vNormal = normalize(uNormalMat * nrm);
  vFlatNormal = normalize(uNormalMat * nrm);
  vOutline = uOutline;
  gl_Position = projectionMatrix * viewMatrix * wp;
}
`;

export const SKIN_FRAG = /* glsl */ `
precision highp float;

uniform vec3 uLightDir;      // world-space, points FROM the light
uniform vec3 uLightColor;
uniform vec3 uAmbient;
uniform vec3 uTintA;         // main body colour
uniform vec3 uTintB;         // accent (belly / boot / wing membrane)
uniform float uBands;        // number of toon steps along the terminator
uniform float uRim;          // rim strength
uniform float uRimWidth;
uniform vec3 uOutlineColor;
uniform float uDebugPart;    // 1 = flat-per-primitive debug colouring
uniform float uDebugSeam;    // 1 = highlight the joint blend windows
uniform float uToon;         // 0 = smooth lambert, 1 = banded toon
uniform float uFog;          // debug: attenuate with distance to read depth
uniform vec3 uFogColor;

varying vec3 vNormal;
varying vec3 vFlatNormal;
varying vec3 vWorld;
varying float vPartId;
varying vec3 vLocal;
varying float vOutline;
varying float vBlend;

float saturate1(float x) { return clamp(x, 0.0, 1.0); }

float hash11(float p) {
  p = fract(p * 0.1031);
  p *= p + 33.33;
  p *= p + p;
  return fract(p);
}

void main() {
  if (vOutline > 0.0) {
    gl_FragColor = vec4(uOutlineColor, 1.0);
    return;
  }

  vec3 N = normalize(vNormal);
  vec3 V = normalize(cameraPosition - vWorld);
  if (!gl_FrontFacing) N = -N;

  vec3 L = normalize(-uLightDir);
  float ndl = dot(N, L) * 0.5 + 0.5;          // wrapped: no black terminator

  float lit;
  if (uToon > 0.5) {
    // Quantise the wrapped lambertian. Band edges come from the uniform, so the
    // toon look is a dial, not a recompile.
    float bands = max(2.0, uBands);
    lit = floor(saturate1(ndl) * bands + 0.5) / bands;
    lit = mix(0.45, 1.0, lit);
  } else {
    lit = mix(0.45, 1.0, saturate1(ndl));
  }

  vec3 base = mix(uTintA, uTintB, saturate1(vLocal.y * 0.5 + 0.5) * 0.55);

  if (uDebugPart > 0.5) {
    // Flat colour per primitive: this is the "raw primitives" arm of the A/B.
    float h = hash11(vPartId * 7.13 + 1.0);
    base = 0.35 + 0.5 * vec3(hash11(h + 0.1), hash11(h + 0.2), hash11(h + 0.3));
  }

  vec3 color = base * (uAmbient + uLightColor * lit);

  // Rim / fresnel: the cheap silhouette read that makes an untextured body legible.
  float rim = pow(1.0 - saturate1(dot(N, V)), max(1.0, uRimWidth));
  color += uLightColor * rim * uRim * 0.6;

  if (uDebugSeam > 0.5) {
    // The joint blend windows are exactly where the skinning weights mix two
    // bones; marking those vertices shows where the seam work actually is.
    color = mix(color, vec3(1.0, 0.35, 0.1), saturate1(vBlend - 0.06) * 2.2);
  } else if (uDebugSeam < -0.5) {
    // Negative mode: the raw primitives, for the A/B screenshot pair.
    color = mix(color, vec3(0.1, 0.1, 0.12), 0.0);
  }

  if (uFog > 0.5) {
    float d = saturate1(length(cameraPosition - vWorld) / 12.0);
    color = mix(color, uFogColor, d * 0.85);
  }

  gl_FragColor = vec4(color, 1.0);
}
`;

export function makeUniforms(o) {
  return {
    uBones: { value: o.bones },
    uModel: { value: o.model },
    uNormalMat: { value: o.normalMat },
    uOutline: { value: 0 },
    uHardSeam: { value: 0 },
    uLightDir: { value: o.lightDir },
    uLightColor: { value: o.lightColor },
    uAmbient: { value: o.ambient },
    uTintA: { value: o.tintA },
    uTintB: { value: o.tintB },
    uBands: { value: o.bands ?? 3 },
    uRim: { value: o.rim ?? 0.5 },
    uRimWidth: { value: o.rimWidth ?? 2.5 },
    uOutlineColor: { value: o.outlineColor },
    uDebugPart: { value: 0 },
    uDebugSeam: { value: 0 },
    uToon: { value: 1 },
    uFog: { value: 0 },
    uFogColor: { value: [0.05, 0.06, 0.09] },
  };
}
