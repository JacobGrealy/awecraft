// AC-0035: web night-sky stars (index.html :718-730). The MeshInstance "Stars"
// carries the web's exact 500 mulberry32(42) points (r=320 sphere, local space)
// and follows the camera transform every frame, so local space == view space:
// the (UV - 0.5) quad offset below IS the view-space billboard (web size 1.8
// px -> 0.70 world units at r=320 / fov 75). u_opacity = 1 - day (web :1347).
// No fog() call = web fog:false; depth draw off = web depthWrite:false.
shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled;

uniform float u_opacity = 1.0;
uniform float quad_size = 0.70;

void vertex() {
	VERTEX = vec3(VERTEX) + vec3((UV - 0.5) * quad_size, 0.0);
}

void fragment() {
	ALBEDO = vec3(1.0);
	ALPHA = u_opacity;
}
