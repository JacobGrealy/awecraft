// AC-0090 — the prototype page: scene, layout, camera, control loop.
//
// Scale handling is deliberate: five body plans come out of the generator at
// wildly different sizes (a 1.8 m biped next to a 0.4 m flyer). Rather than
// expose plan units, each character is normalised to a common DISPLAY height,
// and every panel reports both the plan's real height and the display scale, so
// the normalisation is visible rather than hidden.

import * as THREE from 'three';
import { buildPreset, PRESET_ORDER, tints } from './presets.js';
import { Rig } from './rig.js';
import { generate, digest } from './geom.js';
import { Locomotion } from './anim.js';
import { Character } from './skin.js';
import { remeshPlan } from './metaball.js';
import { buildUI } from './ui.js';

const DISPLAY_HEIGHT = 1.05;   // world units every character is scaled to
export const TIERS = ['remesh', 'smooth', 'hard'];

const state = {
  seed: 1,
  tier: 'smooth',
  speed: 1,
  selected: 'biped',
  moveAll: false,
  outline: true,
  wire: false,
  joints: false,
  seamDebug: false,
  partDebug: false,
  toon: true,
  bands: 3,
  autoTour: false,
  tourT: 0,
  frames: 0,
  fps: 0,
  frameMs: 0,
  lastFrameMs: [],
};

const characters = [];
let scene, camera, renderer, canvas, ui, clock;
let grid;
const raycaster = new THREE.Raycaster();
const pointer = new THREE.Vector2();
const pickPlane = new THREE.Plane(new THREE.Vector3(0, 0, 1), 0);

// -------------------------------------------------------------- ground ----

function makeGrid() {
  const size = 60;
  const divisions = 60;
  const geo = new THREE.BufferGeometry();
  const pts = [];
  for (let i = 0; i <= divisions; i++) {
    const t = -size / 2 + (i / divisions) * size;
    pts.push(-size / 2, 0, t, size / 2, 0, t);
    pts.push(t, 0, -size / 2, t, 0, size / 2);
  }
  geo.setAttribute('position', new THREE.Float32BufferAttribute(pts, 3));
  const mat = new THREE.LineBasicMaterial({
    color: 0x2a3a4a, transparent: true, opacity: 0.55,
  });
  const lines = new THREE.LineSegments(geo, mat);
  lines.frustumCulled = false;
  return lines;
}

// ------------------------------------------------------------ character ---

function buildCharacter(preset, seed, index) {
  const plan = buildPreset(preset, seed);
  const rig = new Rig(plan);
  const mesh = generate(plan, { budget: 1 });
  mesh.digest = digest(mesh);
  plan.digest = mesh.digest;
  // The implicit tier transfers its skin weights from this mesh, so it needs a
  // handle on it. See metaball.js transferSkin().
  plan.__sourceMesh = mesh;

  const ch = new Character({ preset, plan, rig, mesh, index, seeds: seed });
  ch.loco = new Locomotion(rig, plan);
  // Zero-fill the bone block so a rig with fewer bones than MAX_BONES never
  // reads uninitialised matrix data in the vertex shader.
  for (let i = 0; i < rig.count; i++) ch.boneData[i * 16] = 1;
  ch.boneData[5] = 1; ch.boneData[10] = 1; ch.boneData[15] = 1;
  for (let i = rig.count; i < 96; i++) {
    ch.boneData[i * 16] = 1; ch.boneData[i * 16 + 5] = 1;
    ch.boneData[i * 16 + 10] = 1; ch.boneData[i * 16 + 15] = 1;
  }
  return ch;
}

function layout() {
  const scales = characters.map((c) => DISPLAY_HEIGHT / Math.max(0.2, c.plan.height));
  const widths = characters.map((c, i) => {
    const half = Math.max(
      Math.abs(c.plan.bbox.min[0]), Math.abs(c.plan.bbox.max[0]),
      Math.abs(c.plan.bbox.min[2]), Math.abs(c.plan.bbox.max[2]));
    return half * 2 * scales[i];
  });
  const gaps = characters.map((_, i) => (i === 0 ? 0 : 0.55));
  let total = gaps.reduce((a, b) => a + b, 0);
  for (let i = 0; i < widths.length; i++) total += widths[i];
  let x = -total / 2;
  characters.forEach((c, i) => {
    const w = widths[i];
    const scale = scales[i];
    c.place(x + w / 2, 0, scale);
    c.displayWidth = w;
    c.displayHeight = DISPLAY_HEIGHT;
    c.baseX = x + w / 2;
    x += w + gaps[i];
  });
}

function applyTier(tier) {
  state.tier = tier;
  for (const c of characters) {
    // The remesh tier replaces the geometry; the smooth/hard tiers share one.
    c.setDebug({ hard: tier === 'hard' });
  }
}

function rebuildRemesh(ch) {
  const t0 = performance.now();
  const result = remeshPlan(ch.plan, { resolution: ch.remeshResolution || 42 });
  const ms = performance.now() - t0;
  if (!result) return null;
  // Keep the ORIGINAL smooth geometry for the smooth/hard tiers; the remesh is
  // an extra object so switching tiers is a visibility change, not a rebuild.
  if (!ch.remeshMesh) {
    const geo = new THREE.BufferGeometry();
    geo.setAttribute('position', new THREE.BufferAttribute(result.positions, 3));
    geo.setAttribute('normal', new THREE.BufferAttribute(result.normals, 3));
    geo.setAttribute('aFlatNormal', new THREE.BufferAttribute(result.normals, 3));
    geo.setAttribute('aBi', new THREE.BufferAttribute(result.bi, 4, false));
    geo.setAttribute('aBw', new THREE.BufferAttribute(result.bw, 4));
    geo.setAttribute('aPartId', new THREE.BufferAttribute(new Float32Array(result.partIds), 1));
    geo.setIndex(new THREE.BufferAttribute(result.indices, 1));
    geo.computeBoundingSphere();
    const t = tints(ch.plan.palette);
    const mat = ch.material.clone();
    mat.uniforms.uBones.value = ch.boneData;
    ch.remeshMesh = new THREE.Mesh(geo, mat);
    ch.remeshMesh.frustumCulled = false;
    ch.group.add(ch.remeshMesh);
  } else {
    ch.remeshMesh.geometry.dispose();
    const geo = new THREE.BufferGeometry();
    geo.setAttribute('position', new THREE.BufferAttribute(result.positions, 3));
    geo.setAttribute('normal', new THREE.BufferAttribute(result.normals, 3));
    geo.setAttribute('aFlatNormal', new THREE.BufferAttribute(result.normals, 3));
    geo.setAttribute('aBi', new THREE.BufferAttribute(result.bi, 4, false));
    geo.setAttribute('aBw', new THREE.BufferAttribute(result.bw, 4));
    geo.setAttribute('aPartId', new THREE.BufferAttribute(new Float32Array(result.partIds), 1));
    geo.setIndex(new THREE.BufferAttribute(result.indices, 1));
    geo.computeBoundingSphere();
    ch.remeshMesh.geometry = geo;
  }
  ch.remeshStats = {
    ms: Math.round(ms * 10) / 10,
    vertices: result.positions.length / 3,
    triangles: result.indices.length / 3,
    resolution: result.resolution,
    welded: result.welded,
  };
  return ch.remeshStats;
}

// ---------------------------------------------------------------- camera ---

let pixelCache = null;

const cam = {
  target: new THREE.Vector3(0, 0.55, 0),
  dist: 6.2,
  azimuth: Math.PI * 0.5,
  elevation: 0.30,
  dragging: false,
  panning: false,
  lastX: 0,
  lastY: 0,
};

function cameraUpdate() {
  const e = cam.elevation;
  const a = cam.azimuth;
  camera.position.set(
    cam.target.x + Math.cos(a) * Math.cos(e) * cam.dist,
    cam.target.y + Math.sin(e) * cam.dist,
    cam.target.z + Math.sin(a) * Math.cos(e) * cam.dist,
  );
  camera.lookAt(cam.target);
}

function attachControls(el) {
  el.addEventListener('pointerdown', (ev) => {
    el.setPointerCapture(ev.pointerId);
    if (ev.button === 2 || ev.shiftKey) { cam.panning = true; } else { cam.dragging = true; }
    cam.lastX = ev.clientX;
    cam.lastY = ev.clientY;
  });
  el.addEventListener('pointermove', (ev) => {
    if (!cam.dragging && !cam.panning) return;
    const dx = ev.clientX - cam.lastX;
    const dy = ev.clientY - cam.lastY;
    cam.lastX = ev.clientX;
    cam.lastY = ev.clientY;
    if (cam.dragging) {
      cam.azimuth -= dx * 0.008;
      cam.elevation = Math.max(-0.25, Math.min(1.35, cam.elevation + dy * 0.006));
    } else {
      const right = new THREE.Vector3().setFromMatrixColumn(camera.matrixWorld, 0);
      const up = new THREE.Vector3().setFromMatrixColumn(camera.matrixWorld, 1);
      const k = cam.dist * 0.0016;
      cam.target.addScaledVector(right, -dx * k);
      cam.target.addScaledVector(up, dy * k);
    }
    cameraUpdate();
  });
  const end = (ev) => {
    cam.dragging = false;
    cam.panning = false;
  };
  el.addEventListener('pointerup', end);
  el.addEventListener('pointercancel', end);
  el.addEventListener('pointerleave', end);
  el.addEventListener('wheel', (ev) => {
    ev.preventDefault();
    cam.dist = Math.max(1.2, Math.min(24, cam.dist * (1 + Math.sign(ev.deltaY) * 0.09)));
    cameraUpdate();
  }, { passive: false });
  el.addEventListener('contextmenu', (ev) => ev.preventDefault());
}

function focusCharacter(name) {
  const ch = characters.find((c) => c.preset === name);
  if (!ch) return;
  cam.target.set(ch.group.position.x, DISPLAY_HEIGHT * 0.5, 0);
  cam.dist = Math.max(2.2, ch.displayWidth * 2.6);
  cameraUpdate();
  state.focused = name;
}

function frameAll() {
  const min = Math.min(...characters.map((c) => c.baseX - c.displayWidth / 2));
  const max = Math.max(...characters.map((c) => c.baseX + c.displayWidth / 2));
  cam.target.set((min + max) / 2, DISPLAY_HEIGHT * 0.5, 0);
  const span = max - min;
  const vFov = (camera.fov * Math.PI) / 180;
  cam.dist = (span / 2) / Math.tan(vFov / 2) * 1.25;
  cameraUpdate();
  state.focused = null;
}

// ------------------------------------------------------------------ init ---

export async function boot() {
  canvas = document.getElementById('c');
  // Reading the framebuffer back (window.__AC0090.capturePixels, used by the
  // verification harness) needs the drawing buffer preserved — otherwise the
  // browser discards it after presenting the frame and readPixels returns stale
  // content, which read as "no control changes anything". It costs a copy per
  // frame, so it is opt-in: load the page with ?preserve=1 to verify.
  const preserve = new URLSearchParams(location.search).has('preserve');
  renderer = new THREE.WebGLRenderer({
    canvas, antialias: true, alpha: false, powerPreference: 'high-performance',
    preserveDrawingBuffer: preserve,
  });
  renderer.setPixelRatio(Math.min(2, window.devicePixelRatio || 1));
  scene = new THREE.Scene();
  scene.background = new THREE.Color(0x0a1018);
  camera = new THREE.PerspectiveCamera(42, 1, 0.05, 200);
  clock = new THREE.Clock();

  grid = makeGrid();
  scene.add(grid);
  const hemi = new THREE.HemisphereLight(0xbcd8ff, 0x2a2f38, 0.55);
  scene.add(hemi);

  for (let i = 0; i < PRESET_ORDER.length; i++) {
    const ch = buildCharacter(PRESET_ORDER[i], state.seed, i);
    scene.add(ch.group);
    characters.push(ch);
  }
  layout();
  resize();
  attachControls(canvas);
  cameraUpdate();
  frameAll();

  ui = buildUI({
    state, characters, TIERS,
    onTier: (tier) => {
      if (tier === 'remesh') ensureRemesh();
      applyTier(tier);
    },
    onSpeed: (v) => {
      state.speed = v;
      for (const c of characters) c.loco.setSpeed(v);
    },
    onRegenerate: (seed) => regenerate(seed),
    onFocus: (name) => focusCharacter(name),
    onFrameAll: () => frameAll(),
    onSelect: (name) => {
      state.selected = name;
      for (const c of characters) c.loco.setSpeed(c.preset === name || state.moveAll ? state.speed : 0);
    },
    onMoveAll: (on) => {
      state.moveAll = on;
      for (const c of characters) c.loco.setSpeed(on || c.preset === state.selected ? state.speed : 0);
    },
    onDebug: (patch) => applyDebug(patch),
    onAutoTour: (on) => { state.autoTour = on; state.tourT = 0; },
  });

  applyDebug({});
  applyTier(state.tier);
  window.addEventListener('resize', resize);
  window.__AC0090 = testApi();
  renderer.setAnimationLoop(frame);
  return window.__AC0090;
}

function ensureRemesh() {
  for (const c of characters) {
    if (!c.remeshMesh) rebuildRemesh(c);
  }
}

function regenerate(seed) {
  state.seed = seed;
  for (const c of characters) {
    const ch = buildCharacter(c.preset, seed, c.index);
    scene.remove(c.group);
    c.group.traverse((o) => {
      if (o.geometry) o.geometry.dispose();
      if (o.material && o.material.dispose && o !== c.material) o.material.dispose();
    });
    characters[c.index] = ch;
    ch.loco.setSpeed(c.preset === state.selected || state.moveAll ? state.speed : 0);
    scene.add(ch.group);
  }
  layout();
  applyTier(state.tier);
  applyDebug({});
  if (state.tier === 'remesh') ensureRemesh();
  frameAll();
  ui.refresh();
}

function applyDebug(patch) {
  Object.assign(state, patch);
  for (const c of characters) {
    c.setDebug({
      hard: state.tier === 'hard',
      wire: state.wire,
      joints: state.joints,
      outline: state.outline,
    });
    c.setOutline(state.outline ? 0.016 : 0);
    c.setBands(state.bands);
    c.setToon(state.toon);
    c.setDebugSeam(state.seamDebug);
    c.setDebugParts(state.partDebug);
    if (c.remeshMesh) c.remeshMesh.visible = state.tier === 'remesh';
    c.meshObj.visible = state.tier !== 'remesh' && state.tier !== 'hard';
    c.hardObj.visible = state.tier === 'hard';
  }
}

function resize() {
  const w = Math.max(1, canvas.clientWidth);
  const h = Math.max(1, canvas.clientHeight);
  renderer.setSize(w, h, false);
  camera.aspect = w / h;
  camera.updateProjectionMatrix();
}

// ----------------------------------------------------------------- frame ---

function frame() {
  const dt = Math.min(0.05, clock.getDelta());
  const t0 = performance.now();

  if (state.autoTour) {
    state.tourT += dt;
    if (state.tourT > 3.4) {
      state.tourT = 0;
      const order = ['all', ...PRESET_ORDER];
      const cur = order.indexOf(state.focused || 'all');
      const next = order[(cur + 1) % order.length];
      if (next === 'all') frameAll(); else focusCharacter(next);
      if (ui) ui.setFocus(state.focused || 'all');
    }
  }

  for (const c of characters) {
    c.loco.update(dt);
    c.syncBones();
  }
  // The ground scrolls at each character's own derived forward speed. Because
  // the stance foot travels backwards exactly one stride per stance period, the
  // scroll rate IS the walk speed — so the planted foot stays planted in world
  // space. Foot lock by construction, not by fudge.
  const fastest = characters.reduce((a, c) => Math.max(a, c.loco.forwardSpeed), 0);
  grid.position.z = (grid.position.z + fastest * dt) % 1;

  for (const c of characters) c.update(dt, state);

  if (state.focused) {
    const ch = characters.find((x) => x.preset === state.focused);
    if (ch) {
      cam.target.x += (ch.group.position.x - cam.target.x) * Math.min(1, dt * 6);
      cameraUpdate();
    }
  }

  renderer.render(scene, camera);
  // Sample the framebuffer NOW, while the drawing buffer is still valid. Reading
  // it from a later task (which is what a test API called between frames does)
  // returns an empty buffer — that is what produced "colors 1 -> 1" for every
  // control in the first verification run.
  pixelCache = readPixelStats();

  const ms = performance.now() - t0;
  state.frames++;
  state.frameMs = state.frameMs * 0.9 + ms * 0.1;
  state.lastFrameMs.push(ms);
  if (state.lastFrameMs.length > 240) state.lastFrameMs.shift();
  if (ui) ui.tick(dt, state, characters);
}

// -------------------------------------------------------------- test API ---

// Read the framebuffer into a small set of summary statistics. Called at the end
// of every rendered frame, so these are the pixels that were actually presented.
function readPixelStats() {
  const gl = renderer.getContext();
  const w = renderer.domElement.width;
  const h = renderer.domElement.height;
  const buf = new Uint8Array(w * h * 4);
  gl.readPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, buf);
  const colors = new Set();
  let nonBg = 0;
  let sum = 0;
  let dark = 0;
  const n = w * h;
  for (let i = 0; i < buf.length; i += 4) {
    const r = buf[i], g = buf[i + 1], b = buf[i + 2];
    const l = (r + g + b) / 3;
    sum += l;
    if (l < 12) dark++;
    colors.add(((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3));
    if (l > 30 && !(Math.abs(r - 10) < 6 && Math.abs(g - 16) < 6 && Math.abs(b - 24) < 6)) nonBg++;
  }
  return {
    width: w,
    height: h,
    distinctColors: colors.size,
    nonBackgroundFraction: Math.round((nonBg / n) * 10000) / 10000,
    meanLuma: Math.round((sum / n) * 100) / 100,
    darkFraction: Math.round((dark / n) * 10000) / 10000,
  };
}

function testApi() {
  return {
    ready: true,
    presets: PRESET_ORDER,
    state,
    info() {
      return {
        seed: state.seed,
        tier: state.tier,
        focused: state.focused || null,
        characters: characters.map((c) => {
          const s = c.stats();
          return {
            ...s,
            displayScale: Math.round(c.sceneScale * 10000) / 10000,
            displayWidth: Math.round(c.displayWidth * 1000) / 1000,
            forwardSpeed: Math.round(c.loco.forwardSpeed * 1000) / 1000,
            cycleHz: Math.round(c.loco.stats.cycleHz * 1000) / 1000,
            phase: Math.round(c.loco.phase * 1000) / 1000,
            remesh: c.remeshStats || null,
          };
        }),
      };
    },
    stats() {
      const arr = state.lastFrameMs.slice(-120);
      const sorted = [...arr].sort((a, b) => a - b);
      const p = (q) => (sorted.length ? sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))] : 0);
      return {
        frames: state.frames,
        drawCalls: renderer.info.render.calls,
        triangles: renderer.info.render.triangles,
        programs: renderer.info.programs ? renderer.info.programs.length : -1,
        geometries: renderer.info.memory.geometries,
        frameMsP50: Math.round(p(0.5) * 100) / 100,
        frameMsP95: Math.round(p(0.95) * 100) / 100,
        frameMsP99: Math.round(p(0.99) * 100) / 100,
        frameMsMax: Math.round((sorted[sorted.length - 1] || 0) * 100) / 100,
        framesSampled: arr.length,
      };
    },
    set(patch) {
      if (patch.speed !== undefined) {
        ui.setSpeed(patch.speed);
      }
      if (patch.tier) { if (patch.tier === 'remesh') ensureRemesh(); applyTier(patch.tier); }
      if (patch.seed !== undefined) regenerate(patch.seed);
      if (patch.focus !== undefined) {
        if (!patch.focus || patch.focus === 'all') frameAll(); else focusCharacter(patch.focus);
        ui.setFocus(state.focused || 'all');
      }
      const dbg = {};
      // Return the applied state so a caller can verify a control actually took,
      // instead of inferring it from whether the pixels moved.
      for (const k of ['wire', 'joints', 'outline', 'seamDebug', 'partDebug', 'toon', 'bands', 'moveAll']) {
        if (patch[k] !== undefined) dbg[k] = patch[k];
      }
      if (Object.keys(dbg).length) { applyDebug(dbg); ui.syncFromState(); }
      // Read back AFTER applyDebug: reading before it reports the previous values,
      // which made every control look like it had failed to take.
      const applied = {};
      for (const k of Object.keys(dbg)) applied[k] = state[k];
      if (patch.tier !== undefined) applied.tier = state.tier;
      // Report what is actually in effect, so a caller can assert a control took
      // rather than inferring it from whether the frame changed. Some controls are
      // legitimately subtle in pixels (the toon on/off pair differs by one
      // quantisation step on most of the surface) and some are unmistakable; the
      // state check covers both, the pixel check does not.
      return {
        info: this.info(),
        state: {
          tier: state.tier, toon: state.toon, bands: state.bands, outline: state.outline,
          wire: state.wire, joints: state.joints, partDebug: state.partDebug,
          seamDebug: state.seamDebug, moveAll: state.moveAll, speed: state.speed,
          focused: state.focused,
        },
        applied: applied,
      };
    },
    // Camera control. `target` is an optional world-space [x, y, z] so a caller
    // can frame a specific joint — the seam A/B needs a joint filling the frame
    // before the normal difference is worth more than a handful of pixels.
    camera(azimuth, elevation, dist, target) {
      if (azimuth !== undefined) cam.azimuth = azimuth;
      if (elevation !== undefined) cam.elevation = elevation;
      if (dist !== undefined) cam.dist = dist;
      if (target) cam.target.set(target[0], target[1], target[2]);
      cameraUpdate();
      return {
        azimuth: cam.azimuth, elevation: cam.elevation, dist: cam.dist,
        target: [cam.target.x, cam.target.y, cam.target.z],
      };
    },
    // Names and world positions of a character's joints, so a caller can pick a
    // real articulation to inspect rather than guessing a coordinate.
    joints(index = 0) {
      const c = characters[index];
      if (!c) return null;
      c.group.updateMatrix();
      const m = c.group.matrix;
      const out = {};
      c.rig.names.forEach((name, i) => {
        const rest = c.plan.joints[i].joint;
        const v = new THREE.Vector3(rest[0], rest[1], rest[2]).applyMatrix4(m);
        out[name] = [v.x, v.y, v.z];
      });
      return { preset: c.preset, scale: c.group.scale.x, joints: out };
    },
    // Screen-space probe. Reads the cached stats captured at the end of the last
    // rendered frame; call window.__AC0090.capturePixels() first if the page has
    // not rendered since the last change.
    pixelStats() {
      return pixelCache || { error: 'no frame rendered yet' };
    },
    capturePixels() {
      renderer.render(scene, camera);
      pixelCache = readPixelStats();
      return pixelCache;
    },
    // Numeric seam metric: how much the surface normal disagrees with the
    // per-face normal. A joint blend spreads the normal across the articulation
    // ring, so the mean disagreement (and its p95) RISES while the maximum
    // discontinuity FALLS — the seam stops being a crease.
    seamMetric() {
      return characters.map((c) => normalMetric(c.mesh, c.preset));
    },
    // Diagnostic: what the shader is actually being told, and what is visible.
    debugState() {
      return {
        camera: { az: cam.azimuth, el: cam.elevation, dist: cam.dist,
                  target: [cam.target.x, cam.target.y, cam.target.z],
                  pos: [camera.position.x, camera.position.y, camera.position.z] },
        characters: characters.map((c) => ({
          preset: c.preset,
          groupVisible: c.group.visible,
          groupPos: [c.group.position.x, c.group.position.y, c.group.position.z],
          scale: c.group.scale.x,
          meshVisible: c.meshObj.visible,
          hardVisible: c.hardObj.visible,
          outlineVisible: c.outlineObj.visible,
          wireVisible: c.wire.visible,
          uDebugSeam: c.material.uniforms.uDebugSeam.value,
          uDebugPart: c.material.uniforms.uDebugPart.value,
          uToon: c.material.uniforms.uToon.value,
          uBands: c.material.uniforms.uBands.value,
          uOutline: c.outlineMaterial.uniforms.uOutline.value,
          verts: c.mesh.vertexCount,
        })),
        render: {
          calls: renderer.info.render.calls,
          triangles: renderer.info.render.triangles,
          size: [renderer.domElement.width, renderer.domElement.height],
          canvasCss: [canvas.clientWidth, canvas.clientHeight],
        },
      };
    },
    // Where does a character actually land on screen? Projects the skinned mesh
    // bounds through the live camera; a mesh that is off-screen or sub-pixel is
    // what "the page renders nothing" usually turns out to mean.
    project(index) {
      const c = characters[index || 0];
      if (!c) return null;
      const m = c.group.matrixWorld;
      camera.updateMatrixWorld();
      let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
      let behind = 0;
      const v = new THREE.Vector3();
      const p = c.mesh.positions;
      for (let i = 0; i < p.length; i += 3) {
        v.set(p[i], p[i + 1], p[i + 2]).applyMatrix4(m);
        const view = v.clone().applyMatrix4(camera.matrixWorldInverse);
        if (view.z > -camera.near) { behind++; continue; }
        const ndc = v.clone().project(camera);
        minX = Math.min(minX, ndc.x); maxX = Math.max(maxX, ndc.x);
        minY = Math.min(minY, ndc.y); maxY = Math.max(maxY, ndc.y);
      }
      const px = (ndcX, w) => (ndcX * 0.5 + 0.5) * w;
      const W = renderer.domElement.width;
      const H = renderer.domElement.height;
      return {
        preset: c.preset,
        ndc: [minX, minY, maxX, maxY].map((n) => Math.round(n * 100) / 100),
        screenPx: {
          x0: Math.round(px(minX, W)), x1: Math.round(px(maxX, W)),
          y0: Math.round(px(minY, H)), y1: Math.round(px(maxY, H)),
        },
        widthPx: Math.round((maxX - minX) * 0.5 * W),
        heightPx: Math.round((maxY - minY) * 0.5 * H),
        verticesBehindCamera: behind,
        canvas: [W, H],
      };
    },
    boneState() {
      // Cheap per-frame fingerprint of the pose, used by the "every plan
      // actually animates" gate.
      return characters.map((c) => {
        let s = 0;
        for (let i = 0; i < c.rig.count * 16; i++) s += Math.abs(c.rig.flatSkin[i]) * (i % 7 + 1);
        return { preset: c.preset, sig: Math.round(s * 1000) / 1000, phase: c.loco.phase };
      });
    },
    dispose() {
      renderer.setAnimationLoop(null);
    },
  };
}

// Mean / max disagreement between a vertex's smooth normal and its face normal,
// plus the largest normal jump between adjacent vertices. Reported raw so the
// numbers can be compared between arms rather than summarised into a verdict.
export function normalMetric(mesh, preset) {
  const n = mesh.normals;
  const f = mesh.flatNormals;
  let sum = 0;
  const diffs = [];
  for (let i = 0; i < n.length; i += 3) {
    const d = n[i] * f[i] + n[i + 1] * f[i + 1] + n[i + 2] * f[i + 2];
    const ang = Math.acos(Math.max(-1, Math.min(1, d)));
    sum += ang;
    diffs.push(ang);
  }
  diffs.sort((a, b) => a - b);
  const mean = sum / diffs.length;
  const p95 = diffs[Math.floor(diffs.length * 0.95)];
  return {
    preset,
    vertices: diffs.length,
    meanNormalVsFaceDeg: Math.round((mean * 180 / Math.PI) * 100) / 100,
    p95NormalVsFaceDeg: Math.round((p95 * 180 / Math.PI) * 100) / 100,
  };
}
