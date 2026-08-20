# 0.1.0

Initial release.

- `GlassBackdropScope` + `LiquidGlassContainer`: single-pass fragment-shader
  liquid glass (refraction, dispersion, fresnel, glare, backdrop blur, tint,
  superellipse corners, drop shadow), ported from
  [liquid-glass-studio](https://github.com/iyinchao/liquid-glass-studio).
- Hashed backdrop capture: zero per-frame rasterizations over a static
  backdrop, per-container crops on animated backdrops.
- Glass-through-glass compositing for overlapping panes.
- BackdropFilter-based fallback on CanvasKit (dart2js) web builds.
- Optional `child`, laid out centered on the pane.
