// Shared between glass_main.frag and glass_overlay.frag (impellerc includes
// the shader's own directory on every target, web included). Requires the
// including shader to declare: u_scopeRes, u_dpr, u_size, u_shapeRadius,
// u_shapeRoundness, u_shadowOffset, u_shadowExpand, u_shadowFactor.

const float PI = 3.14159265359;

// ---- lib/math.glsl ----

float safeAsin(float x) {
  return asin(clamp(x, -1.0, 1.0));
}

// ---- lib/sdf.glsl (u_showShape1 == 0: circle SDF is constant 1.0, and
// smin(1.0, d, 0.05) == d for every d near the shape — merge dropped) ----

float superellipseCornerSDF(vec2 p, float r, float n) {
  p = abs(p);
  return pow(pow(p.x, n) + pow(p.y, n), 1.0 / n) - r;
}

float roundedRectSDF(vec2 p, float width, float height, float cornerRadius, float n) {
  float cr = cornerRadius * u_dpr;
  vec2 d = abs(p) - vec2(width * u_dpr, height * u_dpr) * 0.5;
  if (d.x > -cr && d.y > -cr) {
    vec2 cornerCenter = sign(p) * (vec2(width * u_dpr, height * u_dpr) * 0.5 - vec2(cr));
    return superellipseCornerSDF(p - cornerCenter, cr, n);
  }
  return min(max(d.x, d.y), 0.0) + length(max(d, 0.0));
}

// p: device px from the glass center (y-down; the SDF is y-symmetric).
// Normalized by scope height like the reference (shape params are logical px,
// scaled to device inside roundedRectSDF).
float mainSDF(vec2 p) {
  return roundedRectSDF(
    p / u_scopeRes.y,
    u_size.x / u_scopeRes.y,
    u_size.y / u_scopeRes.y,
    u_shapeRadius / u_scopeRes.y,
    u_shapeRoundness
  );
}

vec2 getNormal(vec2 p) {
  // central differences over 1 device px, like the reference
  vec2 grad = vec2(
    mainSDF(p + vec2(1.0, 0.0)) - mainSDF(p - vec2(1.0, 0.0)),
    mainSDF(p + vec2(0.0, 1.0)) - mainSDF(p - vec2(0.0, 1.0))
  ) / 2.0;
  return grad * 1.414213562 * 1000.0;
}

vec2 safeNormalize(vec2 v) {
  float len = length(v);
  if (len < 1e-8) return vec2(0.0);
  return v / len;
}

float vec2ToAngle(vec2 v) {
  float angle = atan(v.y, v.x);
  if (angle < 0.0) angle += 2.0 * PI;
  return angle;
}

// pow(x, 5.0) is undefined in GLSL for x < 0 (reference relies on the driver's
// NaN/negative result being clamped to 0); compute the signed odd power
// explicitly so every backend lands on the same well-defined 0.
float pow5clamp01(float x) {
  return clamp(sign(x) * pow(abs(x), 5.0), 0.0, 1.0);
}

// ---- lib/color.glsl (D65 paths only; matrices applied row-vector * mat like
// the reference, i.e. effectively transposed — intentional, do not "fix") ----

const vec3 WHITE = vec3(0.95045592705, 1.0, 1.08905775076);
const mat3 RGB_TO_XYZ_M = mat3(
  0.4124, 0.3576, 0.1805,
  0.2126, 0.7152, 0.0722,
  0.0193, 0.1192, 0.9505
);
const mat3 XYZ_TO_RGB_M = mat3(
   3.2406255, -1.537208 , -0.4986286,
  -0.9689307,  1.8757561,  0.0415175,
   0.0557101, -0.2040211,  1.0569959
);

float UNCOMPAND_SRGB(float a) {
  return a > 0.04045 ? pow((a + 0.055) / 1.055, 2.4) : a / 12.92;
}

float COMPAND_RGB(float a) {
  return a <= 0.0031308 ? 12.92 * a : 1.055 * pow(a, 0.41666666666) - 0.055;
}

vec3 SRGB_TO_RGB(vec3 srgb) {
  return vec3(UNCOMPAND_SRGB(srgb.x), UNCOMPAND_SRGB(srgb.y), UNCOMPAND_SRGB(srgb.z));
}

vec3 RGB_TO_SRGB(vec3 rgb) {
  return vec3(COMPAND_RGB(rgb.x), COMPAND_RGB(rgb.y), COMPAND_RGB(rgb.z));
}

float XYZ_TO_LAB_F(float x) {
  return x > 0.00885645167 ? pow(x, 0.333333333) : 7.78703703704 * x + 0.13793103448;
}

vec3 XYZ_TO_LAB(vec3 xyz) {
  vec3 s = xyz / WHITE;
  s = vec3(XYZ_TO_LAB_F(s.x), XYZ_TO_LAB_F(s.y), XYZ_TO_LAB_F(s.z));
  return vec3(116.0 * s.y - 16.0, 500.0 * (s.x - s.y), 200.0 * (s.y - s.z));
}

vec3 SRGB_TO_LCH(vec3 srgb) {
  vec3 lab = XYZ_TO_LAB(SRGB_TO_RGB(srgb) * RGB_TO_XYZ_M);
  return vec3(lab.x, sqrt(dot(lab.yz, lab.yz)), atan(lab.z, lab.y) * 57.2957795131);
}

float LAB_TO_XYZ_F(float x) {
  return x > 0.206897 ? x * x * x : 0.12841854934 * (x - 0.137931034);
}

vec3 LCH_TO_SRGB(vec3 lch) {
  vec3 lab = vec3(lch.x, lch.y * cos(lch.z * 0.01745329251), lch.y * sin(lch.z * 0.01745329251));
  float w = (lab.x + 16.0) / 116.0;
  vec3 xyz = WHITE * vec3(LAB_TO_XYZ_F(w + lab.y / 500.0), LAB_TO_XYZ_F(w), LAB_TO_XYZ_F(w - lab.z / 200.0));
  return RGB_TO_SRGB(xyz * XYZ_TO_RGB_M);
}

// ---- shadow (reference fragment-bg.glsl folded in; evaluated at the sampled
// backdrop position so it refracts like the baked original) ----

float shadowTerm(vec2 p) {
  float sd = mainSDF(p - u_shadowOffset * u_dpr);
  return exp(-abs(sd) * (u_scopeRes.y / u_dpr) / u_shadowExpand) * 0.6 * u_shadowFactor;
}
