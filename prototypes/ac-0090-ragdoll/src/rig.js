// AC-0090 — the rig: bone frames, posing and skin matrices.
//
// A bone is a joint plus a parent. Its local frame is chosen ONCE, at build
// time, from the direction of its rest child (see rigAxes) so that:
//
//   * `swing` (rotation about the frame X) is the same motion on every bone —
//     for a limb pointing outward it moves the limb forward/backward in the
//     sagittal plane;
//   * `bend`  (rotation about the frame Z) is the hinge — same sign on the left
//     and right sides, so a mirrored limb bends the same way without special
//     cases;
//   * mirroring a limb x -> -x leaves both axes unchanged, because the frame X
//     is derived from the direction crossed with world up.
//
// Rotation is applied about the joint in world-aligned axes (see mat4.js), so
// chaining parent -> child needs no basis-change boilerplate.

import { m4, m4mul, m4invert, m4fromRotAround, m4fromQuat, m4xformPoint } from './mat4.js';

export function rigAxes(plan) {
  const axes = plan.joints.map(() => null);
  for (const b of plan.joints) {
    // Direction the bone points, at rest: towards its first child's joint.
    let dir = null;
    for (const c of plan.joints) {
      if (c.parent === b.index) { dir = sub(c.joint, b.joint); break; }
    }
    if (!dir || len(dir) < 1e-6) {
      // Leaf bone: use the parent's direction so hands/feet keep the chain frame.
      if (b.parent >= 0) dir = sub(b.joint, plan.joints[b.parent].joint);
      else dir = [0, 1, 0];
    }
    if (len(dir) < 1e-6) dir = [0, 1, 0];
    const y = norm(dir);
    let x = cross([0, 1, 0], y);
    if (len(x) < 1e-4) x = cross([0, 0, 1], y);
    x = norm(x);
    const z = norm(cross(x, y));
    axes[b.index] = { x, y, z };
  }
  return axes;
}

const sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
const len = (a) => Math.hypot(a[0], a[1], a[2]);
const norm = (a) => { const l = len(a) || 1; return [a[0] / l, a[1] / l, a[2] / l]; };

export class Rig {
  constructor(plan) {
    this.plan = plan;
    this.axes = rigAxes(plan);
    const n = plan.joints.length;
    this.count = n;
    this.names = plan.joints.map((b) => b.name);
    this.index = {};
    for (const b of plan.joints) this.index[b.name] = b.index;

    // Inverse bind pose, per bone: the inverse of the rest world matrix, which
    // for character-space geometry is simply T(-joint).
    //
    // This is NOT the identity, and getting it wrong is subtle: with B^-1 = I the
    // skinning matrix degenerates to a rotation about the WORLD ORIGIN instead of
    // about the bone's own joint. Each bone then looks right in isolation while
    // every articulation tears, because a vertex in a blend window is pulled by
    // two bones swinging about different centres. The measured symptom was a 19x
    // edge stretch at the elbow, with a still frame that looked fine.
    this.restInv = plan.joints.map((b) => {
      const restWorld = m4();
      restWorld[12] = b.joint[0];
      restWorld[13] = b.joint[1];
      restWorld[14] = b.joint[2];
      return m4invert(m4(), restWorld);
    });
    this.local = plan.joints.map(() => [0, 0, 0]);
    this.world = plan.joints.map(() => m4());
    this.skin = plan.joints.map(() => m4());
    this.flatSkin = new Float32Array(n * 16);
    // Bind-pose-relative offsets used by the animation rig.
    this.restPos = plan.joints.map((b) => b.joint.slice());
    this.restDir = plan.joints.map((b) => {
      const a = this.axes[b.index];
      return a ? a.y.slice() : [0, 1, 0];
    });
    this.restQuat = plan.joints.map(() => identityQuat());
    this._tmpParent = [0, 0, 0];
  }

  bone(name) {
    const i = this.index[name];
    if (i === undefined) throw new Error(`no bone "${name}"`);
    return i;
  }

  has(name) {
    return this.index[name] !== undefined;
  }

  reset() {
    for (let i = 0; i < this.count; i++) this.local[i] = [0, 0, 0];
  }

  // Local rotation for a bone, expressed on its own frame:
  //   swing — about frame X (limb forward/back)
  //   bend  — about frame Z (hinge: knee/elbow)
  //   twist — about frame Y (limb roll)
  set(name, swing, bend, twist = 0) {
    const i = typeof name === 'number' ? name : this.bone(name);
    this.local[i] = [swing, bend, twist];
  }

  add(name, swing, bend, twist = 0) {
    const i = typeof name === 'number' ? name : this.bone(name);
    const l = this.local[i];
    l[0] += swing; l[1] += bend; l[2] += twist;
  }

  // World position of a joint from the CURRENT pose (what IK needs).
  worldPos(name, out) {
    const i = typeof name === 'number' ? name : this.bone(name);
    const m = this.world[i];
    out[0] = m[12]; out[1] = m[13]; out[2] = m[14];
    return out;
  }

  // Forward kinematics.
  //
  // Geometry is authored in CHARACTER SPACE and each bone's rest world matrix is
  // T(joint), so a bone poses correctly when its vertices are carried with the
  // PARENT (inheriting the parent's motion) and then rotated about the bone's
  // OWN joint:
  //
  //   world[root]  = T(j) * R                       (nothing above it to inherit)
  //   world[child] = world[parent] * T(-j_child) * R_child * T(j_child)
  //
  // The `T(-j) ... T(j)` conjugation is the whole trick: without it the child
  // rotates about its PARENT's origin, so a vertex near the joint is dragged by
  // one bone and pinned by the other and the skin tears. Without the root's
  // `T(j)` the root sits at the origin and the whole body pivots about the world
  // origin. Both mistakes were made here; both produce a still frame that looks
  // like a standing creature, and both show up only as an exploding edge-stretch
  // number. That is why tools/meshcheck.mjs asserts the rest pose AND the stretch.
  //
  // At the rest pose (all R = I) both forms collapse to T(joint), so the skin
  // matrix (world * restInv) is the identity and the mesh sits exactly on bind.
  update() {
    const plan = this.plan;
    const R = this._R || (this._R = m4());
    const tmp = this._local5 || (this._local5 = m4());
    const origin = this._origin || (this._origin = [0, 0, 0]);
    for (let i = 0; i < this.count; i++) {
      const b = plan.joints[i];
      m4fromQuat(R, this.quatFor(i));
      if (b.parent >= 0) {
        const pw = this.world[b.parent];
        // The joint's position AFTER the parent has moved: the child inherits
        // the parent's motion, then rotates about that moved joint.
        m4xformPoint(origin, pw, b.joint[0], b.joint[1], b.joint[2]);
        m4fromRotAround(tmp, this.quatFor(i), origin, origin);
      } else {
        m4fromRotAround(tmp, this.quatFor(i), b.joint, b.joint);
      }
      this.world[i].set(tmp);
      m4mul(this.skin[i], this.world[i], this.restInv[i]);
      this.flatSkin.set(this.skin[i], i * 16);
    }
    return this;
  }


  quatFor(i) {
    const a = this.axes[i];
    const [sw, bd, tw] = this.local[i];
    // q = qX(swing) * qZ(bend) * qY(twist), each about the bone's own axis, so
    // composition order is stable regardless of how the limb is oriented.
    const qx = axisQuat(a.x, sw);
    const qz = axisQuat(a.z, bd);
    const qy = axisQuat(a.y, tw);
    return qmul(qx, qmul(qz, qy));
  }
}

function identityQuat() {
  return [0, 0, 0, 1];
}

function axisQuat(axis, angle) {
  if (angle === 0) return [0, 0, 0, 1];
  const h = angle * 0.5;
  const s = Math.sin(h);
  return [axis[0] * s, axis[1] * s, axis[2] * s, Math.cos(h)];
}

function qmul(a, b) {
  const ax = a[0], ay = a[1], az = a[2], aw = a[3];
  const bx = b[0], by = b[1], bz = b[2], bw = b[3];
  return [
    aw * bx + ax * bw + ay * bz - az * by,
    aw * by - ax * bz + ay * bw + az * bx,
    aw * bz + ax * by - ay * bx + az * bw,
    aw * bw - ax * bx - ay * by - az * bz,
  ];
}
