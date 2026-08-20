#version 460 core

// Lighting-only companion to glass_main.frag for the CanvasKit fallback:
// interior shadow, tint, fresnel, and glare, drawn srcOver on top of a
// BackdropFilter-blurred backdrop. No samplers, so no toImageSync feeds.
// Output is premultiplied. Deviations from glass_main.frag: the interior
// shadow darkens multiplicatively (over-black) instead of subtracting, and
// glare brightens a white/tint base instead of the sampled backdrop pixel.

#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 u_scopeRes;     // backdrop scope size, device px
uniform float u_dpr;
uniform vec2 u_drawOrigin;   // glass rect top-left in canvas space, logical px
uniform vec2 u_size;         // glass size, logical px
uniform float u_shapeRadius; // logical px
uniform float u_shapeRoundness;
uniform vec4 u_tint;
uniform float u_refThickness;
uniform float u_refFactor;
uniform float u_refFresnelRange;
uniform float u_refFresnelHardness;
uniform float u_refFresnelFactor;
uniform float u_glareRange;
uniform float u_glareHardness;
uniform float u_glareConvergence;
uniform float u_glareOppositeFactor;
uniform float u_glareFactor;
uniform float u_glareAngle;
uniform float u_shadowExpand;
uniform float u_shadowFactor;
uniform vec2 u_shadowOffset; // shadow shape offset, logical px, y-down

#include "glass_lib.glsl"

out vec4 fragColor;

// src-over of (rgb, a) on top of premultiplied acc
vec4 over(vec3 rgb, float a, vec4 acc) {
  return vec4(rgb * a, a) + acc * (1.0 - a);
}

void main() {
  vec2 local = FlutterFragCoord().xy - u_drawOrigin; // logical px in the rect
  vec2 pDev = local * u_dpr;                         // glass-local device px
  vec2 p = pDev - u_size * u_dpr * 0.5;              // centered device px
  float res1xy = u_scopeRes.y / u_dpr;

  float merged = mainSDF(p);
  vec4 acc = vec4(0.0);

  if (merged < 0.005) {
    float nmerged = -1.0 * (merged * res1xy);

    // interior shadow + tint, same stacking as the interior branch of
    // glass_main.frag
    acc = over(vec3(0.0), clamp(shadowTerm(p), 0.0, 1.0), acc);
    acc = over(u_tint.rgb, u_tint.a * 0.8, acc);

    // same edge gate as the refraction branch
    float x_R_ratio = 1.0 - nmerged / u_refThickness;
    float thetaI = safeAsin(pow(x_R_ratio, 2.0));
    float thetaT = safeAsin(1.0 / u_refFactor * sin(thetaI));
    float edgeFactor = -1.0 * tan(thetaT - thetaI);

    if (nmerged < u_refThickness && edgeFactor > 0.0) {
      vec2 normal = getNormal(p); // y-down

      // fresnel
      float fresnelFactor = pow5clamp01(
        1.0 + merged * res1xy / 1500.0 * pow(500.0 / u_refFresnelRange, 2.0) +
          u_refFresnelHardness);

      vec3 fresnelTintLCH = SRGB_TO_LCH(mix(vec3(1.0), u_tint.rgb, u_tint.a * 0.5));
      fresnelTintLCH.x += 20.0 * fresnelFactor * u_refFresnelFactor;
      fresnelTintLCH.x = clamp(fresnelTintLCH.x, 0.0, 100.0);

      acc = over(
        LCH_TO_SRGB(fresnelTintLCH),
        clamp(fresnelFactor * u_refFresnelFactor * 0.7 * length(normal), 0.0, 1.0),
        acc);

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

      vec3 glareTintLCH = SRGB_TO_LCH(mix(vec3(1.0), u_tint.rgb, u_tint.a * 0.5));
      glareTintLCH.x += 150.0 * glareAngleFactor * glareGeoFactor;
      glareTintLCH.y += 30.0 * glareAngleFactor * glareGeoFactor;
      glareTintLCH.x = clamp(glareTintLCH.x, 0.0, 120.0);

      acc = over(
        LCH_TO_SRGB(glareTintLCH),
        clamp(glareAngleFactor * glareGeoFactor * length(normal), 0.0, 1.0),
        acc);
    }
  }

  fragColor = acc;
}
