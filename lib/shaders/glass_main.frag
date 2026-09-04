#version 460 core

// Port of liquid-glass-studio fragment-main.glsl (STEP == 9 branch), reworked
// for a single direct in-scene draw:
//  - coordinates are container-local (FlutterFragCoord is canvas-local on both
//    Skia and Impeller), so the rect can be drawn straight into the frame;
//  - the reference's separate shadow pass is folded in as an analytic term
//    (the SDF is already here; blur(shadow) ~= shadow since it's smooth);
//  - the outside-the-shape edge blend is handled by an AA clip in Dart, so
//    fragments only need the interior branches.
// Scale-sensitive factors keep the reference's u_resolution.y normalization
// (passed as u_scopeRes) for visual parity.

#include <flutter/runtime_effect.glsl>

precision highp float;

const float N_R = 0.98;
const float N_G = 1.0;
const float N_B = 1.02;

uniform vec2 u_scopeRes;     // backdrop scope size, device px
uniform float u_dpr;
uniform vec2 u_drawOrigin;   // glass rect top-left in canvas space, logical px
uniform vec2 u_size;         // glass size, logical px
uniform vec2 u_originScope;  // glass rect top-left in scope space, device px
uniform float u_shapeRadius; // logical px
uniform float u_shapeRoundness;
uniform vec4 u_tint;
uniform float u_refThickness;
uniform float u_refFactor;
uniform float u_refDispersion;
uniform float u_refFresnelRange;
uniform float u_refFresnelHardness;
uniform float u_refFresnelFactor;
uniform float u_glareRange;
uniform float u_glareHardness;
uniform float u_glareConvergence;
uniform float u_glareOppositeFactor;
uniform float u_glareFactor;
uniform float u_glareAngle;
uniform float u_blurEdge;
uniform float u_shadowExpand;
uniform float u_shadowFactor;
uniform vec2 u_shadowOffset; // shadow shape offset, logical px, y-down
// The sampled textures are crops of the scope backdrop (scope device px),
// sized so every sampled kernel stays inside — see Dart margins.
uniform vec2 u_cropOrigin;
uniform vec2 u_cropSize;

uniform sampler2D u_blurredBg;
uniform sampler2D u_bg;

out vec4 fragColor;

// scope-space device px -> crop-texture uv (same uv for both textures: the
// blurred one is just a lower-resolution raster of the same crop rect)
vec2 toCrop(vec2 posDev) {
  vec2 uv = (posDev - u_cropOrigin) / u_cropSize;
#ifdef IMPELLER_TARGET_OPENGLES
  // GLES render targets are stored bottom-up; drawImage compensates but
  // runtime-effect samplers get the raw texture. Both samplers are always
  // toImageSync render targets, so unconditionally un-flip on this backend.
  uv.y = 1.0 - uv.y;
#endif
  return uv;
}

#include "glass_lib.glsl"

// ---- dispersion (samplers accessed globally, like the reference WGSL) ----

vec4 getTextureDispersion(vec2 posDev, float mixRate, vec2 offset, float factor) {
  vec4 pixel = vec4(1.0);

  float bgR = texture(u_bg, toCrop(posDev + offset * (1.0 - (N_R - 1.0) * factor))).r;
  float bgG = texture(u_bg, toCrop(posDev + offset * (1.0 - (N_G - 1.0) * factor))).g;
  float bgB = texture(u_bg, toCrop(posDev + offset * (1.0 - (N_B - 1.0) * factor))).b;

  float blurR = texture(u_blurredBg, toCrop(posDev + offset * (1.0 - (N_R - 1.0) * factor))).r;
  float blurG = texture(u_blurredBg, toCrop(posDev + offset * (1.0 - (N_G - 1.0) * factor))).g;
  float blurB = texture(u_blurredBg, toCrop(posDev + offset * (1.0 - (N_B - 1.0) * factor))).b;

  pixel.r = mix(bgR, blurR, mixRate);
  pixel.g = mix(bgG, blurG, mixRate);
  pixel.b = mix(bgB, blurB, mixRate);

  return pixel;
}

void main() {
  vec2 local = FlutterFragCoord().xy - u_drawOrigin; // logical px in the rect
  vec2 pDev = local * u_dpr;                         // glass-local device px
  vec2 p = pDev - u_size * u_dpr * 0.5;              // centered device px
  vec2 fragScopeDev = u_originScope + pDev;          // scope device px
  float res1xy = u_scopeRes.y / u_dpr;

  float merged = mainSDF(p);

  vec4 outColor;

  if (merged < 0.005) {
    float nmerged = -1.0 * (merged * res1xy);

    // refraction edge factor; guarded: thickness 0 would divide by zero (a
    // NaN ring in the AA fringe), and interior fragments skip the trig
    float edgeFactor = 0.0;
    if (u_refThickness > 0.0 && nmerged < u_refThickness) {
      float x_R_ratio = 1.0 - nmerged / u_refThickness;
      float thetaI = safeAsin(x_R_ratio * x_R_ratio);
      float thetaT = safeAsin(1.0 / u_refFactor * sin(thetaI));
      edgeFactor = -1.0 * tan(thetaT - thetaI);
    }

    if (edgeFactor <= 0.0) {
      outColor = texture(u_blurredBg, toCrop(fragScopeDev));
      outColor.rgb -= vec3(shadowTerm(p));
      outColor = mix(outColor, vec4(u_tint.rgb, 1.0), u_tint.a * 0.8);
    } else {
      float edgeH = nmerged / u_refThickness;
      vec2 normal = getNormal(p); // y-down
      float blurMixRate = u_blurEdge > 0.0 ? 1.0 : edgeH;

      // reference refOffset folded to device px (isotropic; the aspect factor
      // in the original exactly cancels the per-axis uv scale)
      vec2 refOffset = -normal * edgeFactor * 0.05 * u_dpr * u_scopeRes.y;
      vec4 blurredPixel = getTextureDispersion(
        fragScopeDev, blurMixRate, refOffset, u_refDispersion);
      blurredPixel.rgb -= vec3(shadowTerm(p + refOffset));

      // basic tint
      outColor = mix(blurredPixel, vec4(u_tint.rgb, 1.0), u_tint.a * 0.8);

      // fresnel
      float fresnelFactor = pow5clamp01(
        1.0 + merged * res1xy / 1500.0 * pow(500.0 / u_refFresnelRange, 2.0) +
          u_refFresnelHardness);

      vec3 fresnelTintLCH = SRGB_TO_LCH(mix(vec3(1.0), u_tint.rgb, u_tint.a * 0.5));
      fresnelTintLCH.x += 20.0 * fresnelFactor * u_refFresnelFactor;
      fresnelTintLCH.x = clamp(fresnelTintLCH.x, 0.0, 100.0);

      outColor = mix(
        outColor,
        vec4(LCH_TO_SRGB(fresnelTintLCH), 1.0),
        fresnelFactor * u_refFresnelFactor * 0.7 * normalWeight(normal));

      // glare (reference math is y-up: flip the normal for the angle)
      float glareGeoFactor = pow5clamp01(
        1.0 + merged * res1xy / 1500.0 * pow(500.0 / u_glareRange, 2.0) +
          u_glareHardness);

      vec2 normalUp = vec2(normal.x, -normal.y);
      float glareAngle = (vec2ToAngle(safeNormalize(normalUp)) - PI / 4.0 + u_glareAngle) * 2.0;
      float glareSideFactor =
        (glareAngle > PI * (2.0 - 0.5) && glareAngle < PI * (4.0 - 0.5)) ||
            glareAngle < PI * (0.0 - 0.5)
          ? 1.2 * u_glareOppositeFactor
          : 1.2;

      float glareAngleFactor = (0.5 + sin(glareAngle) * 0.5) * glareSideFactor * u_glareFactor;
      glareAngleFactor = clamp(pow(glareAngleFactor, 0.1 + u_glareConvergence * 2.0), 0.0, 1.0);

      vec3 glareTintLCH = SRGB_TO_LCH(mix(blurredPixel.rgb, u_tint.rgb, u_tint.a * 0.5));
      glareTintLCH.x += 150.0 * glareAngleFactor * glareGeoFactor;
      glareTintLCH.y += 30.0 * glareAngleFactor * glareGeoFactor;
      glareTintLCH.x = clamp(glareTintLCH.x, 0.0, 120.0);

      outColor = mix(
        outColor,
        vec4(LCH_TO_SRGB(glareTintLCH), 1.0),
        clamp(glareAngleFactor * glareGeoFactor * normalWeight(normal),
          0.0, 1.0));
    }
  } else {
    // only reachable in the AA fringe of the clip: match the backdrop
    outColor = texture(u_bg, toCrop(fragScopeDev));
  }

  fragColor = vec4(outColor.rgb, 1.0);
}
