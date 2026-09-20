// AC-0090 — turn a generated mesh + rig into drawable objects.
//
// Three quality tiers share ONE program each, so the cost of the technique is
// visible as geometry and draw calls rather than as shader variants:
//
//   hard       — the raw primitives: flat per-primitive normals, no joint
//                smooth-shading. The "before" arm of the A/B.
//   smooth     — the same geometry with the baked per-vertex blend: joint
//                normals and weights interpolate across the articulation.
//   remesh     — the same shapes polygonised as one implicit surface with a
//                smooth-min union (metaball.js): one seamless body, no seams to
//                blend because there are no separate surfaces left.
//
// A material is per-character (uniforms differ) but the program is shared via a
// shared cache key, which is what THREE keys programs on.

import * as THREE from 'three';
import { SKIN_VERT, SKIN_FRAG, MAX_BONES } from './shaders.js';
import { tints } from './presets.js';

const programCache = new Map();
function sharedProgramKey(cacheKey, def) {
  let key = programCache.get(cacheKey);
  if (!key) {
    key = `ac0090-${cacheKey}-${programCache.size}`;
    programCache.set(cacheKey, key);
  }
  def.customProgramCacheKey = () => key;
  return def;
}

export function makeSkinMaterial(opts) {
  const material = new THREE.ShaderMaterial({
    vertexShader: SKIN_VERT,
    fragmentShader: SKIN_FRAG,
    uniforms: {
      uBones: { value: opts.bones },
      uModel: { value: new THREE.Matrix4() },
      uNormalMat: { value: new THREE.Matrix3() },
      uOutline: { value: 0 },
      uHardSeam: { value: opts.hardSeam ? 1 : 0 },
      uLightDir: { value: new THREE.Vector3(0.45, 0.85, 0.3).normalize() },
      uLightColor: { value: new THREE.Color(1.0, 0.97, 0.9) },
      uAmbient: { value: new THREE.Color(0.30, 0.33, 0.40) },
      uTintA: { value: new THREE.Color(...opts.tintA) },
      uTintB: { value: new THREE.Color(...opts.tintB) },
      uBands: { value: 3 },
      uRim: { value: 0.45 },
      uRimWidth: { value: 2.4 },
      uOutlineColor: { value: new THREE.Color(...opts.outline) },
      uDebugPart: { value: opts.debugParts ? 1 : 0 },
      uDebugSeam: { value: opts.debugSeam ? 1 : 0 },
      uToon: { value: 1 },
      uFog: { value: 0 },
      uFogColor: { value: new THREE.Color(0.05, 0.06, 0.09) },
    },
    side: opts.side ?? THREE.FrontSide,
    transparent: false,
    depthWrite: true,
  });
  if (opts.debugParts) material.uniforms.uDebugPart.value = 1;
  return sharedProgramKey(opts.cacheKey, material);
}

export function buildGeometry(mesh) {
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.BufferAttribute(mesh.positions, 3));
  g.setAttribute('normal', new THREE.BufferAttribute(mesh.normals, 3));
  g.setAttribute('aFlatNormal', new THREE.BufferAttribute(mesh.flatNormals, 3));
  g.setAttribute('aBi', new THREE.BufferAttribute(normalizeBoneIdx(mesh.bi, mesh.boneCount), 4));
  g.setAttribute('aBw', new THREE.BufferAttribute(mesh.bw, 4));
  g.setAttribute('aPartId', new THREE.BufferAttribute(partIdFloats(mesh.partIds), 1));
  g.setIndex(new THREE.BufferAttribute(mesh.indices, 1));
  g.computeBoundingSphere();
  g.computeBoundingBox();
  // The toon rim and outline read the silhouette, so the bounding sphere must
  // account for the outline shell push.
  g.boundingSphere.radius *= 1.05;
  return g;
}

function normalizeBoneIdx(bi, boneCount) {
  // THREE maps Int8/Uint8 to normalized attribute types unpredictably across
  // versions; Uint16 is the safe, universally supported index attribute here
  // and the memory difference is irrelevant next to the weights.
  const out = new Uint16Array(bi.length);
  for (let i = 0; i < bi.length; i++) {
    const v = bi[i];
    out[i] = v < boneCount ? v : 0;   // guard: never index past uBones[N]
  }
  return out;
}

function partIdFloats(ids) {
  const out = new Float32Array(ids.length);
  for (let i = 0; i < ids.length; i++) out[i] = ids[i];
  return out;
}

export class Character {
  constructor({ preset, plan, rig, mesh, index, seeds }) {
    this.preset = preset;
    this.plan = plan;
    this.rig = rig;
    this.mesh = mesh;
    this.index = index;
    this.seeds = seeds;

    this.boneData = new Float32Array(MAX_BONES * 16);
    this._normalMat = new THREE.Matrix3();
    this.geometry = buildGeometry(mesh);

    const t = tints(plan.palette || 'mint');
    this.tints = t;

    this.material = makeSkinMaterial({
      bones: this.boneData,
      tintA: t.a, tintB: t.b, outline: t.outline,
      cacheKey: `skin-${preset}`,
    });
    this.hardMaterial = makeSkinMaterial({
      bones: this.boneData,
      tintA: t.a, tintB: t.b, outline: t.outline,
      cacheKey: `hard-${preset}`,
    });
    this.hardMaterial.uniforms.uHardSeam.value = 1;
    // A second u8-free variant is not needed: the outline reuses the same
    // program with uOutline > 0, so it costs a draw call, not a program.
    this.outlineMaterial = makeSkinMaterial({
      bones: this.boneData,
      tintA: t.a, tintB: t.b, outline: t.outline,
      cacheKey: `skin-${preset}`,
      side: THREE.BackSide,
    });
    this.outlineMaterial.uniforms.uOutline.value = 1;

    this.meshObj = new THREE.Mesh(this.geometry, this.material);
    this.meshObj.frustumCulled = false;
    this.meshObj.matrixAutoUpdate = true;
    this.hardObj = new THREE.Mesh(this.geometry, this.hardMaterial);
    this.hardObj.frustumCulled = false;
    this.hardObj.visible = false;
    this.outlineObj = new THREE.Mesh(this.geometry, this.outlineMaterial);
    this.outlineObj.frustumCulled = false;
    this.outlineObj.renderOrder = -1;

    this.group = new THREE.Group();
    this.group.add(this.meshObj);
    this.group.add(this.hardObj);
    this.group.add(this.outlineObj);

    this.wire = new THREE.Mesh(
      this.geometry,
      new THREE.MeshBasicMaterial({
        color: 0x9fe8c8, wireframe: true, transparent: true, opacity: 0.22,
      }),
    );
    this.wire.frustumCulled = false;
    this.wire.visible = false;
    this.group.add(this.wire);

    // Joint markers for the skeleton view.
    this.bones = new THREE.Group();
    this.bones.visible = false;
    const jointGeo = new THREE.SphereGeometry(1, 6, 5);
    const jointMat = new THREE.MeshBasicMaterial({ color: 0xffb066 });
    for (const j of plan.joints) {
      const m = new THREE.Mesh(jointGeo, jointMat);
      m.position.set(j.joint[0], j.joint[1], j.joint[2]);
      m.scale.setScalar(Math.max(0.014, j.radius * 0.22));
      this.bones.add(m);
    }
    this.group.add(this.bones);
  }

  setVisible(visible) {
    this.group.visible = visible;
  }

  place(x, z, sceneScale) {
    this.group.position.set(x, 0, z);
    this.group.scale.setScalar(sceneScale);
    this.sceneScale = sceneScale;
  }

  update(dt, opts) {
    const rig = this.rig;
    // Ground offset / squash come from the locomotion rig: applied as a group
    // transform so the skeleton itself stays in character space.
    const loco = this.loco;
    this.group.position.y = (loco ? loco.groundOffset : 0) * (this.sceneScale || 1);
    this.group.rotation.z = loco ? -(loco.bank || 0) : 0;
    this.group.rotation.x = loco ? (loco.rootLean || 0) * 0.15 : 0;

    // Compose the model matrix from the group's OWN transform into a local
    // matrix. This used to alias `this.meshObj.matrixWorld` as the output buffer,
    // so the "sync" wrote the group matrix onto the very object it read from — a
    // no-op — and the body kept the identity uModel its material was constructed
    // with. The mesh was drawn at x = 0 while its object sat at x = -4.91: off
    // screen. The scene graph was correct, the projection maths was right, the
    // shader compiled and linked, and the body simply never appeared — only the
    // outline hull still showed, which is why the page rendered as a faint
    // silhouette rather than as nothing at all.
    const m = new THREE.Matrix4();
    this._syncMatrix(m);

    const mat = this.material.uniforms;
    mat.uBones.value = this.boneData;
    // The body material's model matrix has to be written here too. It was not:
    // only the outline and hard materials were updated, so the body was drawn
    // with the identity matrix its material was constructed with, at world
    // origin, while the outline hull was drawn in the right place.
    mat.uModel.value.copy(m);
    this.outlineMaterial.uniforms.uBones.value = this.boneData;
    this.hardMaterial.uniforms.uBones.value = this.boneData;
    this.hardMaterial.uniforms.uModel.value.copy(m);
    this.outlineMaterial.uniforms.uModel.value.copy(m);
    const nm = this._normalMat.getNormalMatrix(m);
    mat.uNormalMat.value.copy(nm);
    this.outlineMaterial.uniforms.uNormalMat.value.copy(nm);
    this.hardMaterial.uniforms.uNormalMat.value.copy(nm);
  }

  _syncMatrix(m) {
    // Compose the model matrix from the group's own TRS rather than reading
    // meshObj.matrixWorld. Reading matrixWorld here depends on the renderer
    // having already updated the scene graph this frame; when it has not, the
    // uniform silently keeps a stale value — in the failing case the body mesh
    // was drawn with uModel = identity while its object sat at x = -4.91, i.e.
    // 4.9 units off screen, and the page looked like "nothing renders" with a
    // perfectly healthy scene graph, correct projection maths and no GL error.
    this.group.updateMatrix();
    m.copy(this.group.matrix);
  }

  syncBones() {
    this.boneData.set(this.rig.flatSkin);
  }

  setDebug({ hard, wire, joints, outline }) {
    if (hard !== undefined) {
      this.meshObj.visible = !hard;
      this.hardObj.visible = hard;
    }
    if (wire !== undefined) this.wire.visible = wire;
    if (joints !== undefined) this.bones.visible = joints;
    if (outline !== undefined) this.outlineObj.visible = outline;
  }

  setOutline(width) {
    const u = this.outlineMaterial.uniforms.uOutline;
    // The hull is pushed in world units, so undo the group scale to keep the
    // outline a constant on-screen width.
    u.value = width / Math.max(0.001, this.sceneScale || 1);
  }

  setBands(n) {
    this.material.uniforms.uBands.value = n;
    this.hardMaterial.uniforms.uBands.value = n;
  }


  setToon(on) {
    this.material.uniforms.uToon.value = on ? 1 : 0;
    this.hardMaterial.uniforms.uToon.value = on ? 1 : 0;
  }

  setDebugSeam(on) {
    this.material.uniforms.uDebugSeam.value = on ? 1 : 0;
  }

  setDebugParts(on) {
    this.material.uniforms.uDebugPart.value = on ? 1 : 0;
    this.hardMaterial.uniforms.uDebugPart.value = on ? 1 : 0;
  }

  stats() {
    return {
      preset: this.preset,
      palette: this.plan.palette,
      joints: this.plan.joints.length,
      tubes: this.plan.tubeCount,
      lumps: this.plan.lumpCount,
      vertices: this.mesh.vertexCount,
      triangles: this.mesh.triangleCount,
      digest: this.mesh.digest,
      height: this.plan.height,
    };
  }
}
