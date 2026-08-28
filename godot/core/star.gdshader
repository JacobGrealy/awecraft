// AC-0035 (web night-sky stars, index.html :718-730) + AC-0133 (sky-fixed
// orientation). The MeshInstance "Stars" is a child of the world root and is
// recentered on the camera POSITION each frame (web :3248, position copy
// only); its rotation is NEVER set, so the field is fixed in world
// orientation — stars scroll with the sky under camera yaw, no parallax
// under walking. The (UV - 0.5) quad offset is applied in the camera's
// WORLD basis (world-space billboard below), because the node frame no
// longer tracks the camera. u_opacity = 1 - day (web :1347). No fog() call
// = web fog:false; depth draw off = web depthWrite:false.

shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled;

uniform float u_opacity = 1.0;
uniform float quad_size = 0.70;

void vertex() {
	vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;          // star center, world space
	mat3 v = mat3(VIEW_MATRIX);
	vec3 cam_right = transpose(v) * vec3(1.0, 0.0, 0.0);       // row 0 of the view rotation = camera right (world)
	vec3 cam_up = transpose(v) * vec3(0.0, 1.0, 0.0);          // row 1 = camera up (world)
	vec3 off = (cam_right * (UV.x - 0.5) + cam_up * (UV.y - 0.5)) * quad_size;
	VERTEX = w + off - MODEL_MATRIX[3].xyz;                    // back to node-local (node basis = identity, origin = eye)
}

void fragment() {
	ALBEDO = vec3(1.0);
	ALPHA = u_opacity;
}
