// The civilians' animation (docs/design/ambient-life.md "Civilian animation: as built"; user pick "Build C": shader
// limbs + character). One rigid-part civilian mesh (LifeAnimRig.build_mesh: UV.x = part id, UV.y = colour slot) drawn
// by ONE MultiMesh per deck (LifeFigures) and posed here, in the vertex shader, from per-instance custom data. The same
// vertex function runs in the shadow pass, so shadows follow the pose. Lit like CityPalette.surface_material(): vertex
// colour (sRGB) as albedo, roughness 1, metallic 0, specular 0.1; normals rotate with their part (flat shading intact).
//
// INSTANCE_CUSTOM (LifeAnimRig.pack, written only when a person's motion changes or a turn starts):
//   x  motion + 16 * previous motion + 256 * clothes (0..7) + 2048 * talk + 4096 * (turn / 5 deg + 36)
//   y  life-clock time the motion began, minus LifeFigures' epoch (s)
//   z  1024 * walking speed (cm/s) + seed (0..1023)
//   w  walk / run: metres walked at y (the stride runs from distance: feet do not slide); fall: the fall direction
//      (radians, model space: 0 = forward, PI = backward); otherwise 0
// anim_time: the life clock minus the same epoch, set once a frame (AmbientLife.now: the shared net clock online, the
// local clock x time_scale offline), so pause, lab speed and net time just work. Nothing else changes per frame.
// Exaggeration (LifeAnimRig.EXAGGERATION, x1.3) scales the acting amplitudes; leg swing comes from the stride.
shader_type spatial;
render_mode cull_back;

uniform float anim_time = 0.0;
uniform float character = 1.0;
uniform float exaggeration = 1.3;
uniform float blend_s = 0.3;
uniform float run_speed = 4.5;
uniform float turn_tau = 0.16;
uniform vec3 shirts[8];
uniform vec3 trousers[8];

const int M_IDLE = 0;
const int M_WALK = 1;
const int M_RUN = 2;
const int M_COWER = 3;
const int M_FLINCH = 4;
const int M_FALL = 5;
const int M_SIT = 6;
const int M_HANDS = 7;
const int M_LOOK = 8;

struct Pose {
	vec4 root;    // x sway (m, +X), y bob (m), z body yaw, w pelvis roll
	vec4 spine;   // x lean forward, y twist (shoulders vs pelvis), z roll, w pelvis yaw
	vec4 head;    // x pitch (down +), y yaw (left +), z roll, w -
	vec4 al;      // left arm (+X): x swing forward, y raise sideways, z elbow bend, w -
	vec4 ar;      // right arm (-X)
	vec4 ll;      // left leg: x swing forward, y out, z knee bend, w -
	vec4 lr;      // right leg
	vec4 fall;    // x topple angle, y -, z extra lift, w -
};

float h(float s, float k) {
	return fract(sin(s * 91.345 + k * 47.853) * 43758.5453);
}

mat3 rot_x(float a) {
	float c = cos(a); float s = sin(a);
	return mat3(vec3(1.0, 0.0, 0.0), vec3(0.0, c, s), vec3(0.0, -s, c));
}

mat3 rot_y(float a) {
	float c = cos(a); float s = sin(a);
	return mat3(vec3(c, 0.0, -s), vec3(0.0, 1.0, 0.0), vec3(s, 0.0, c));
}

mat3 rot_z(float a) {
	float c = cos(a); float s = sin(a);
	return mat3(vec3(c, s, 0.0), vec3(-s, c, 0.0), vec3(0.0, 0.0, 1.0));
}

mat3 rot_axis(vec3 a, float ang) {
	float c = cos(ang); float s = sin(ang); float t = 1.0 - c;
	return mat3(
		vec3(t * a.x * a.x + c, t * a.x * a.y + s * a.z, t * a.x * a.z - s * a.y),
		vec3(t * a.x * a.y - s * a.z, t * a.y * a.y + c, t * a.y * a.z + s * a.x),
		vec3(t * a.x * a.z + s * a.y, t * a.y * a.z - s * a.x, t * a.z * a.z + c));
}

Pose rest() {
	return Pose(vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0, 0.06, 0.12, 0.0), vec4(0.0, 0.06, 0.12, 0.0),
			vec4(0.0, 0.02, 0.03, 0.0), vec4(0.0, 0.02, 0.03, 0.0), vec4(0.0));
}

Pose pmix(Pose a, Pose b, float t) {
	return Pose(mix(a.root, b.root, t), mix(a.spine, b.spine, t), mix(a.head, b.head, t), mix(a.al, b.al, t),
			mix(a.ar, b.ar, t), mix(a.ll, b.ll, t), mix(a.lr, b.lr, t), mix(a.fall, b.fall, t));
}

// Left-handed people: the pose mirrored across the body's mid plane.
Pose mirror(Pose p) {
	vec4 m = vec4(-1.0, 1.0, -1.0, -1.0);
	return Pose(p.root * m, vec4(p.spine.x, -p.spine.y, -p.spine.z, -p.spine.w), vec4(p.head.x, -p.head.y, -p.head.z, 0.0),
			p.ar, p.al, p.lr, p.ll, p.fall);
}

float ss(float a, float b, float x) {
	return smoothstep(a, b, x);
}

// Ease 0..1 that overshoots with character.
float ease(float x) {
	float c = clamp(x, 0.0, 1.0);
	float y = c - 1.0;
	float back = 1.0 + y * y * (2.7 * y + 1.7);
	return mix(c * c * (3.0 - 2.0 * c), back, character);
}

// A sub-action window: 0 outside, 1 for `len` s starting at `at`, eased in and out over `fade` s.
float window(float u, float at, float len, float fade) {
	return ease((u - at) / fade) * (1.0 - ss(at + len - fade, at + len, u));
}

// One leg's swing angle and knee bend at cycle phase q: on the ground for `duty` of the cycle, swinging linearly from +A
// (in front) to -A (behind) so the foot keeps pace with the ground; then lifted (knee) and eased forward again.
vec2 gait(float q, float A, float duty, float knee) {
	q = fract(q);
	if (q < duty) {
		float u = q / duty;
		return vec2(mix(A, -A, u), 0.04 + knee * 0.12 * sin(PI * u));
	}
	float u = (q - duty) / (1.0 - duty);
	float e = u * u * (3.0 - 2.0 * u);
	return vec2(mix(-A, A, e), 0.04 + knee * sin(PI * u));
}

// --- Motions --------------------------------------------------------------------------------------------------
// t: seconds since the motion began; T: the clock (absolute, for cycles that must not restart); d: metres walked.

Pose m_idle(float T, float s, float ex, float ch, int force_v, bool talk) {
	Pose P = rest();
	float w = sin(TAU * T / (5.0 + 2.0 * h(s, 1.0)) + TAU * h(s, 2.0));        // weight shift
	P.root.x = 0.03 * ex * w;
	P.root.w = 0.04 * ex * w * (0.5 + ch);
	P.spine.z = -0.7 * P.root.w;
	P.ll.z = 0.03 + 0.18 * ex * max(0.0, -w);
	P.lr.z = 0.03 + 0.18 * ex * max(0.0, w);
	P.ll.x = 0.09 * ex * max(0.0, -w);
	P.lr.x = 0.09 * ex * max(0.0, w);
	P.ll.y = 0.05; P.lr.y = 0.05;
	P.spine.x = -0.03 + 0.1 * h(s, 3.0) + 0.015 * sin(TAU * T / 3.6);          // posture + breathing
	P.head.x = -0.05 + 0.12 * h(s, 4.0);
	// Sub-actions cycle (look around / wrist / phone / talk); `talk` (someone stands close) mostly talks.
	float period = (force_v == 0 ? 4.2 : 6.0) + 3.0 * h(s, 5.0);
	float cyc = floor(T / period + h(s, 6.0));
	float u = (T / period + h(s, 6.0) - cyc) * period;
	int v = int(mod(floor(h(s, 7.0) * 4.0) + cyc * ch, 4.0));
	if (talk && h(s, 18.0 + cyc) < 0.75) {
		v = 3;
	}
	if (force_v >= 0) {
		v = force_v;
	}
	float a = window(u, 0.8, 3.2, 0.45);
	float side = h(s, 8.0 + cyc) < 0.5 ? 1.0 : -1.0;
	if (v == 0) {          // look around: head leads, the torso turns after it, a glance up
		float ah = window(u, 0.6, 2.6, 0.35);
		float sweep = force_v == 0 ? sin(TAU * (u - 0.6) / 2.6 * 0.5 + (side > 0.0 ? 0.0 : PI)) : side;
		P.head.y = 0.8 * ex * ah * sweep;
		P.spine.y = 0.28 * ch * ex * ah * sweep;
		P.head.y -= P.spine.y * 0.5;
		P.head.x -= 0.12 * ch * ah;
		P.ll.x += 0.06 * ah * sweep; P.lr.x -= 0.06 * ah * sweep;
	} else if (v == 1) {   // check the left wrist
		P.al.x = mix(P.al.x, 1.05, a);
		P.al.y = mix(P.al.y, -0.45, a);
		P.al.z = mix(P.al.z, 1.75, a);
		P.head.x += 0.38 * a;
		P.head.y += 0.25 * a;
		P.spine.y += 0.12 * ch * a;
	} else if (v == 2) {   // phone in the right hand, looks up from it now and then
		P.ar.x = 0.5;
		P.ar.y = -0.3;
		P.ar.z = 1.8;
		P.head.x += 0.45 * (1.0 - a) - 0.05 * a;
		P.head.y += (0.4 * side * ch) * a;
		P.al.z += 0.25 * ch;
	} else {               // talking: hand gestures, torso turned to the listener, head tilts and nods
		float g = sin(T * 3.1 + h(s, 9.0) * TAU);
		float g2 = sin(T * 2.3 + 1.7);
		float on = mix(1.0, a, 0.5);
		P.ar.x = 0.35 + 0.25 * ex * g2 * on;
		P.ar.z = 0.9 + 0.45 * ex * g * on;
		P.ar.y = 0.05 + 0.1 * ch * g;
		P.al.x = mix(P.al.x, 0.3 + 0.2 * ex * g, ch * on);
		P.al.z = mix(P.al.z, 0.8 - 0.4 * ex * g2, ch * on);
		P.head.x += 0.05 * sin(T * 2.6);
		P.head.z = 0.1 * ch * sin(T * 0.9);
		P.spine.y += 0.2 * ch * side;
	}
	if (h(s, 10.0) < 0.2) {
		P = mirror(P);
	}
	return P;
}

Pose m_walk(float d, float T, float s, float ex, float ch) {
	Pose P = rest();
	float stride = 1.35 + 0.3 * h(s, 12.0);                 // m per cycle (two steps)
	float p = d / stride + h(s, 13.0);
	float ph = p * TAU;
	float sn = sin(ph);
	float cs = cos(ph);
	float A = asin(clamp(stride * 0.25 / 0.84, 0.0, 0.8));  // half a step's sweep = what the foot covers on the ground
	vec2 gl = gait(p, A, 0.5, 0.55 * ex);
	vec2 gr = gait(p + 0.5, A, 0.5, 0.55 * ex);
	P.ll.x = gl.x; P.ll.z = gl.y;
	P.lr.x = gr.x; P.lr.z = gr.y;
	float arm = 0.36 * ex * (0.75 + 0.5 * h(s, 14.0));
	P.al.x = -arm * gl.x / A + 0.03;                         // arms swing against the legs
	P.ar.x = -arm * gr.x / A + 0.03;
	P.al.z = 0.18 + 0.3 * ex * max(0.0, P.al.x);
	P.ar.z = 0.18 + 0.3 * ex * max(0.0, P.ar.x);
	P.al.y = 0.07; P.ar.y = 0.07;
	P.spine.x = 0.03 + 0.1 * h(s, 3.0);
	P.head.x = -0.05 + 0.12 * h(s, 4.0);
	// hips drop on the swing side and turn with the leading leg, shoulders counter-rotate, head stays level,
	// elbows lag, now and then a glance aside.
	P.root.w = -0.07 * ch * ex * cs;
	P.spine.z = 0.045 * ch * ex * cs;
	P.spine.w = -0.13 * ch * ex * sn;
	P.spine.y = 0.22 * ch * ex * sn;
	P.head.y = -0.09 * ch * ex * sn;
	P.head.x += 0.03 * ch * cos(2.0 * ph);
	P.al.z += 0.1 * ch * sin(ph + 0.7);
	P.ar.z -= 0.1 * ch * sin(ph + 0.7);
	float gc = floor(T / 4.3 + h(s, 15.0));
	float gu = (T / 4.3 + h(s, 15.0) - gc) * 4.3;
	if (h(s, 16.0 + gc) < 0.5) {
		float g = window(gu, 1.0, 1.1, 0.3) * ch;
		float side = h(s, 17.0 + gc) < 0.5 ? 1.0 : -1.0;
		P.head.y += 0.7 * g * side;
		P.spine.y += 0.15 * g * side;
	}
	if (h(s, 10.0) < 0.2) {
		P = mirror(P);
	}
	return P;
}

Pose m_run(float d, float T, float s, float ex, float ch) {
	Pose P = rest();
	float stride = 2.5 + 0.4 * h(s, 22.0);
	float p = d / stride + h(s, 23.0);
	float ph = p * TAU;
	float sn = sin(ph);
	float duty = 0.38;
	float A = asin(clamp(stride * duty * 0.5 / 0.82, 0.0, 0.85));
	vec2 gl = gait(p, A, duty, 1.35 * ex);
	vec2 gr = gait(p + 0.5, A, duty, 1.35 * ex);
	P.ll.x = 0.1 + gl.x; P.ll.z = 0.2 + gl.y;
	P.lr.x = 0.1 + gr.x; P.lr.z = 0.2 + gr.y;
	P.root.y = 0.06 * ex * abs(sin(ph));
	P.spine.x = 0.3 * ex + 0.06 * ch;
	P.head.x = -0.15;
	if (fract(s * 13.0 + 0.37) < 0.4) {    // 40 % flee with both arms up (the wide silhouette reads at 40 m), waving
		P.al.x = 0.35 + 0.5 * ch * sin(ph * 2.0 + 2.0);
		P.ar.x = 0.35 + 0.5 * ch * sin(ph * 2.0 + 0.4);
		P.al.y = 2.45 + 0.3 * ex * sn + 0.35 * ch * sin(ph * 2.0 + 1.0);
		P.ar.y = 2.45 - 0.3 * ex * sn + 0.35 * ch * sin(ph * 2.0 + 2.6);
		P.al.z = 0.3 + 0.4 * ch * max(0.0, sin(ph * 2.0));
		P.ar.z = 0.3 + 0.4 * ch * max(0.0, -sin(ph * 2.0));
		P.spine.x -= 0.1;
	} else {                   // pumping arms, flailing wide
		P.al.x = -0.85 * ex * gl.x / A;
		P.ar.x = -0.85 * ex * gr.x / A;
		P.al.z = 1.45 - 0.3 * ch * sn;
		P.ar.z = 1.45 + 0.3 * ch * sn;
		P.al.y = 0.15 + 0.5 * ch * (0.5 + 0.5 * sin(ph * 1.5 + 1.3));
		P.ar.y = 0.15 + 0.5 * ch * (0.5 + 0.5 * sin(ph * 1.5 + 4.1));
	}
	// looks back over the shoulder, hips swing, and a stumble every few seconds
	P.spine.w = -0.15 * ch * ex * sn;
	P.spine.y = 0.2 * ch * ex * sn;
	float gc = floor(T / 2.9 + h(s, 25.0));
	float gu = (T / 2.9 + h(s, 25.0) - gc) * 2.9;
	float side = h(s, 26.0 + gc) < 0.5 ? 1.0 : -1.0;
	float look = window(gu, 0.6, 0.7, 0.2) * ch * step(0.4, h(s, 27.0 + gc));
	P.head.y = 1.1 * look * side;
	P.spine.y += 0.35 * look * side;
	float st = window(gu, 1.9, 0.25, 0.18) * ch * step(h(s, 28.0 + gc), 0.45);
	P.spine.x += 0.45 * st;
	P.root.y -= 0.1 * st;
	P.al.y += 0.9 * st; P.ar.y += 0.9 * st;
	P.al.x += 0.7 * st; P.ar.x += 0.7 * st;
	P.ll.z += 0.35 * st; P.lr.z += 0.35 * st;
	P.head.x -= 0.3 * st;
	if (h(s, 10.0) < 0.2) {
		P = mirror(P);
	}
	return P;
}

// Crouched, hands over the head. The way in is the blend from the previous motion (vertex()), never from standing.
Pose m_cower(float t, float T, float s, float ex, float ch) {
	Pose P = rest();
	P.ll.x = 1.55; P.lr.x = 1.55;
	P.ll.z = 2.15; P.lr.z = 2.15;
	P.ll.y = 0.2; P.lr.y = 0.2;
	P.spine.x = 0.8;
	P.head.x = 0.45;
	P.al.x = 2.0; P.ar.x = 2.0;          // hands on top of the head, elbows out
	P.al.y = 0.4; P.ar.y = 0.4;
	P.al.z = 1.6; P.ar.z = 1.6;
	// a flinch up while going down (anticipation), trembling, peeking out now and then
	float pre = ch * (1.0 - ss(0.0, 0.3, t)) * ss(0.0, 0.06, t);
	P.spine.x -= 0.35 * pre;
	P.head.x -= 0.3 * pre;
	P.spine.z += 0.035 * ch * sin(T * 24.0 + h(s, 31.0) * TAU);
	P.al.z += 0.06 * ch * sin(T * 19.0);
	P.ar.z += 0.06 * ch * sin(T * 21.0 + 1.0);
	float pc = floor(T / 3.7 + h(s, 32.0));
	float pu = (T / 3.7 + h(s, 32.0) - pc) * 3.7;
	float peek = ch * window(pu, 1.6, 0.9, 0.25) * step(0.3, h(s, 33.0 + pc)) * step(1.0, t);
	float side = h(s, 34.0 + pc) < 0.5 ? 1.0 : -1.0;
	P.head.x -= 0.65 * peek;
	P.head.y += 0.5 * peek * side;
	P.al.x -= 0.5 * peek; P.ar.x -= 0.5 * peek;
	P.spine.x -= 0.2 * peek;
	if (h(s, 10.0) < 0.2) {
		P = mirror(P);
	}
	return P;
}

// Hands up (a mech close by, no shot for a while): both arms straight up, a half step back, trembling.
Pose m_hands(float t, float T, float s, float ex, float ch) {
	Pose P = rest();
	float wave = sin(T * 5.0 + h(s, 61.0) * TAU);
	P.al.y = 2.85 + 0.08 * ch * wave; P.ar.y = 2.85 - 0.08 * ch * wave;
	P.al.x = 0.15; P.ar.x = 0.15;
	P.al.z = 0.25 + 0.08 * ch * sin(T * 13.0); P.ar.z = 0.25 + 0.08 * ch * sin(T * 11.0 + 1.0);
	P.spine.x = -0.1 * ex;
	P.head.x = -0.2 + 0.1 * ch * sin(T * 0.8 + h(s, 62.0) * TAU);
	P.ll.x = 0.12; P.lr.x = -0.22;
	P.ll.z = 0.12; P.lr.z = 0.08;
	P.ll.y = 0.08; P.lr.y = 0.08;
	P.root.x = 0.02 * ch * sin(T * 2.1);
	return P;
}

Pose m_wary(float T, float ex, float ch) {
	Pose P = rest();
	P.spine.x = -0.12;
	P.ll.x = 0.22; P.lr.x = -0.18;
	P.ll.z = 0.15; P.lr.z = 0.1;
	P.al.x = 1.15; P.ar.x = 1.15;
	P.al.y = 0.3; P.ar.y = 0.3;
	P.al.z = 0.7; P.ar.z = 0.7;
	P.al.z += 0.05 * ch * sin(T * 17.0);
	P.ar.z += 0.05 * ch * sin(T * 15.0 + 1.0);
	return P;
}

// Startled: recoils with forearms up and a step back, then holds wary.
Pose m_flinch(float t, float T, float s, float ex, float ch) {
	Pose P = rest();
	Pose F = rest();
	F.spine.x = -0.4 * ex;
	F.head.x = 0.4 * ex;
	F.head.y = 0.35 * ex * (h(s, 41.0) < 0.5 ? 1.0 : -1.0);
	F.al.x = 1.45; F.ar.x = 1.45;
	F.al.y = -0.05; F.ar.y = -0.05;
	F.al.z = 1.95; F.ar.z = 1.95;
	F.ll.x = 0.25; F.lr.x = 0.25 - 0.6 * ch;       // steps back
	F.ll.z = 0.6 * ex; F.lr.z = 0.6 * ex + 0.2 * ch;
	F.root.y = -0.03 * ex;
	float rise = ss(0.0, 0.08, t);
	float over = 1.0 + 0.35 * ch * (ss(0.05, 0.14, t) - ss(0.14, 0.32, t));   // recoils past, then settles
	float decay = 1.0 - ss(0.3, 0.75, t);
	float hold = ss(0.4, 0.85, t);
	P = pmix(P, F, rise * decay * over);
	P = pmix(P, m_wary(T, ex, ch), hold);
	return P;
}

// Killed: knees buckle, the body twists to face (or turn its back on) the hit direction, topples along it, arms fling,
// one bounce, then settles into one of four sprawls and lies still. fdir: the fall direction (model space).
Pose m_fall(float t, float s, float fdir, float ex, float ch) {
	Pose P = rest();
	float fr = mod(fdir + PI, TAU) - PI;
	bool fwd = abs(fr) <= PI * 0.5;
	float back = fwd ? 0.0 : 1.0;
	float twist = fwd ? fr : fr - sign(fr) * PI;
	P.root.z = twist * ease(t / 0.3);
	float t0 = 0.12 * ch;
	float buckle = ss(0.0, 0.12, t) * (1.0 - ss(0.45, 0.7, t)) * ch;
	float tb = 0.5;
	float f = clamp((t - t0) / tb, 0.0, 1.0);
	float a = PI * 0.5 * f * f;
	float tl = t - t0 - tb;
	float bounce = tl > 0.0 ? (0.16 + 0.1 * ch) * ex * exp(-tl * 7.0) * abs(sin(tl * 11.0)) : 0.0;
	P.fall.x = a - bounce;
	P.ll.z += 0.9 * buckle; P.lr.z += 0.9 * buckle;
	P.ll.x += 0.45 * buckle; P.lr.x += 0.45 * buckle;
	P.spine.x += -0.25 * buckle * (back * 2.0 - 1.0);
	float trail = ss(0.0, 1.0, f);
	P.al.y += (0.5 + 1.2 * ch) * ex * trail;
	P.ar.y += (0.5 + 1.2 * ch) * ex * trail * (0.6 + 0.4 * h(s, 63.0));
	P.al.x += 0.5 * ch * ex * trail * (1.0 - back);
	P.ar.x += 0.3 * ch * ex * trail * (1.0 - back);
	P.head.x += -0.5 * ch * trail * (back * 2.0 - 1.0);      // whiplash against the fall
	P.ll.x += 0.5 * ch * trail * back;                       // a leg kicks up
	// the sprawl (limbs mostly in the body's plane, which lies on the ground)
	float lie = ss(0.1, 0.55, tl);
	int v = int(floor(h(s, 64.0) * 4.0));
	vec4 al = vec4(0.0, 1.5, 0.15, 0.0);
	vec4 ar = vec4(0.0, 0.5, 0.15, 0.0);
	vec4 ll = vec4(0.0, 0.18, 0.05, 0.0);
	vec4 lr = vec4(0.0, 0.06, 0.05, 0.0);
	float hy = 0.6;
	if (v == 1) {          // both arms flung over the head, legs apart
		al.y = 2.6; ar.y = 2.3; ll.y = 0.3; lr.y = 0.25; hy = -0.5;
	} else if (v == 2) {   // one arm up, one along the body, a knee bent
		al.y = 2.4; ar.y = 0.15; ll.y = 0.05; lr.y = 0.3; hy = 0.7;
		ll.x = 0.55 * back; ll.z = 1.1;
	} else if (v == 3) {   // star
		al.y = 1.3; ar.y = 1.25; ll.y = 0.38; lr.y = 0.4; hy = -0.3;
	}
	if (back > 0.5) {      // on its back: a knee may rise (foot on the ground); face down: heels lift instead
		lr.x = 0.25 * h(s, 65.0); lr.z = lr.x * 1.6;
	} else {
		ll.z = 0.35 + 0.3 * h(s, 66.0); lr.z = 0.15;
		ll.x = 0.0;
	}
	P.al = mix(P.al, al, lie);
	P.ar = mix(P.ar, ar, lie);
	P.ll = mix(P.ll, ll, lie);
	P.lr = mix(P.lr, lr, lie);
	P.head.y = mix(P.head.y, hy, lie);
	P.head.x = mix(P.head.x, 0.0, lie);
	P.spine.x = mix(P.spine.x, 0.0, lie);
	if (h(s, 10.0) < 0.2) {    // left-handed: the arms swapped
		vec4 tmp = P.al;
		P.al = P.ar;
		P.ar = tmp;
	}
	return P;
}

Pose m_sit(float T, float s, float ex, float ch) {
	Pose P = rest();
	P.ll.x = 1.35; P.lr.x = 1.35;          // thighs on the seat, shins down to the floor
	P.ll.z = 1.35; P.lr.z = 1.35;
	P.ll.y = 0.04; P.lr.y = 0.04;
	P.spine.x = -0.08 + 0.12 * h(s, 52.0);
	P.al.x = 0.55; P.ar.x = 0.55;
	P.al.z = 0.6; P.ar.z = 0.6;
	P.head.x = 0.05 * sin(T * 0.7 + h(s, 51.0) * TAU) + 0.1 * h(s, 53.0);
	float lc = floor(T / 7.0 + h(s, 54.0));
	float lu = (T / 7.0 + h(s, 54.0) - lc) * 7.0;
	float side = h(s, 55.0 + lc) < 0.5 ? 1.0 : -1.0;
	P.head.y = 0.6 * ch * window(lu, 2.0, 2.0, 0.4) * side * step(0.4, h(s, 56.0 + lc));
	return P;
}

Pose motion(int m, float t, float T, float s, float d, float w, bool talk) {
	float ex = exaggeration;
	float ch = character;
	if (m == M_WALK) { return m_walk(d, T, s, ex, ch); }
	if (m == M_RUN) { return m_run(d, T, s, ex, ch); }
	if (m == M_COWER) { return m_cower(t, T, s, ex, ch); }
	if (m == M_FLINCH) { return m_flinch(t, T, s, ex, ch); }
	if (m == M_FALL) { return m_fall(t, s, w, ex, ch); }
	if (m == M_SIT) { return m_sit(T, s, ex, ch); }
	if (m == M_HANDS) { return m_hands(t, T, s, ex, ch); }
	if (m == M_LOOK) { return m_idle(T, s, ex, ch, 0, false); }
	return m_idle(T, s, ex, ch, -1, talk);
}

// --- Skeleton -----------------------------------------------------------------------------------------------
// Rest (model space, feet at 0, facing +Z, +X = the figure's left): hips 0.86, legs at x +-0.11 (thigh 0.44, shin
// 0.42), shoulders at (+-0.31, 1.46) (upper arm 0.32, forearm 0.32), neck at 1.52. Parts: 0 torso, 1 head, 2/3 upper
// arm L/R, 4/5 forearm L/R, 6/7 thigh L/R, 8/9 shin L/R.

float reach(vec4 leg) {
	return (0.44 * cos(leg.x) + 0.42 * cos(leg.x - leg.z)) * cos(leg.y);
}

vec3 to_linear(vec3 c) {
	return mix(pow((c + vec3(0.055)) * (1.0 / (1.0 + 0.055)), vec3(2.4)), c * (1.0 / 12.92), lessThan(c, vec3(0.04045)));
}

void vertex() {
	vec4 cd = INSTANCE_CUSTOM;
	int code = int(cd.x + 0.5);
	int st = code % 16;
	int prev = (code / 16) % 16;
	int cloth = (code / 256) % 8;
	bool talk = ((code / 2048) % 2) == 1;
	float turn = radians(float(code / 4096 - 36) * 5.0);
	int zi = int(cd.z + 0.5);
	float spd = float(zi / 1024) * 0.01;
	float s = float(zi % 1024) / 1024.0;
	float t = max(anim_time - cd.y, 0.0);
	float T = anim_time + 37.0 * s;
	int slot = int(UV.y + 0.5);
	vec3 col = COLOR.rgb;
	if (slot == 1) {
		col = shirts[cloth];
	} else if (slot == 2) {
		col = trousers[cloth];
	}
	COLOR.rgb = to_linear(col);
	float d = cd.w + t * (st == M_RUN ? run_speed : spd);
	Pose P = motion(st, t, T, s, d, cd.w, talk);
	float bd = (st == M_COWER || st == M_HANDS) ? 0.45 : (st == M_FALL ? 0.18 : blend_s);
	if (prev != st && t < bd) {
		float b = clamp(t / bd, 0.0, 1.0);
		b = b * b * (3.0 - 2.0 * b);
		float dp = T * (prev == M_RUN ? run_speed : spd);
		P = pmix(motion(prev, t + 5.0, T, s, dp, 0.0, talk), P, b);
	}
	// A turn: the drawn heading (LifeFigures) lags the route by exp(-t / turn_tau); head and shoulders lead into it,
	// and a standing person shuffles its feet round.
	if (abs(turn) > 0.01 && st != M_FALL) {
		float g = turn * exp(-t / turn_tau);
		P.head.y += 0.85 * g * character;
		P.spine.y += 0.35 * g * character;
		if (st == M_IDLE || st == M_LOOK || st == M_FLINCH) {
			float stp = clamp(t / 0.6, 0.0, 1.0);
			float on = (1.0 - ss(0.45, 0.6, t)) * min(abs(turn), 1.0);
			P.ll.x += 0.3 * exaggeration * sin(stp * TAU) * on;
			P.ll.z += 0.4 * exaggeration * max(0.0, sin(stp * TAU)) * on;
			P.lr.x += 0.3 * exaggeration * sin(stp * TAU + PI) * on;
			P.lr.z += 0.4 * exaggeration * max(0.0, sin(stp * TAU + PI)) * on;
		}
	}
	int part = int(UV.x + 0.5);
	float side = (part == 2 || part == 4 || part == 6 || part == 8) ? 1.0 : -1.0;
	// the lower foot stays on the ground (the bob comes from the legs)
	float drop = (0.86 - max(reach(P.ll), reach(P.lr))) * cos(P.fall.x);
	vec3 Tr = vec3(P.root.x, P.root.y - drop, 0.0);
	mat3 Rb = rot_y(P.root.z);
	mat3 Rp = Rb * rot_y(P.spine.w) * rot_z(P.root.w);
	vec3 op = Rb * vec3(0.0, 0.86, 0.0) + Tr;
	mat3 Rt = Rp * rot_y(P.spine.y) * rot_x(P.spine.x) * rot_z(P.spine.z);
	mat3 R = Rt;
	vec3 o = op;
	vec3 piv = vec3(0.0, 0.86, 0.0);
	if (part == 1) {
		o = Rt * vec3(0.0, 0.66, 0.0) + op;
		R = Rt * rot_y(P.head.y) * rot_x(P.head.x) * rot_z(P.head.z);
		piv = vec3(0.0, 1.52, 0.0);
	} else if (part >= 2 && part <= 5) {
		vec4 arm = side > 0.0 ? P.al : P.ar;
		vec3 ou = Rt * vec3(side * 0.31, 0.6, 0.0) + op;
		mat3 Ru = Rt * rot_z(side * arm.y) * rot_x(-arm.x);
		R = Ru; o = ou; piv = vec3(side * 0.31, 1.46, 0.0);
		if (part >= 4) {
			o = Ru * vec3(0.0, -0.32, 0.0) + ou;
			R = Ru * rot_x(-arm.z);
			piv = vec3(side * 0.31, 1.14, 0.0);
		}
	} else if (part >= 6) {
		vec4 leg = side > 0.0 ? P.ll : P.lr;
		vec3 ot = Rp * vec3(side * 0.11, 0.0, 0.0) + op;
		mat3 Rh = Rp * rot_z(side * leg.y) * rot_x(-leg.x);
		R = Rh; o = ot; piv = vec3(side * 0.11, 0.86, 0.0);
		if (part >= 8) {
			o = Rh * vec3(0.0, -0.44, 0.0) + ot;
			R = Rh * rot_x(leg.z);
			piv = vec3(side * 0.11, 0.42, 0.0);
		}
	}
	vec3 v = R * (VERTEX - piv) + o;
	vec3 n = R * NORMAL;
	if (st == M_FALL) {
		vec3 dir = vec3(sin(cd.w), 0.0, cos(cd.w));
		vec3 axis = normalize(cross(vec3(0.0, 1.0, 0.0), dir));
		mat3 Rf = rot_axis(axis, P.fall.x);
		vec3 fp = dir * 0.1;
		v = Rf * (v - fp) + fp + vec3(0.0, 0.12 * sin(P.fall.x) + P.fall.z, 0.0);
		n = Rf * n;
	}
	VERTEX = v;
	NORMAL = n;
}

void fragment() {
	ALBEDO = COLOR.rgb;
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
	SPECULAR = 0.1;
}
