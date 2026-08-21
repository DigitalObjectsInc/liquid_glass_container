# 0.1.0

Initial release.

- `GlassBackdropScope` + `LiquidGlassContainer`: single-pass fragment-shader
  liquid glass (refraction, dispersion, fresnel, glare, backdrop blur, tint,
  superellipse corners, drop shadow), ported from
  [liquid-glass-studio](https://github.com/iyinchao/liquid-glass-studio).
- `LiquidGlassSettings`: nullable-field value class resolved field-wise
  (defaults ← scope ← container), with `copyWith`/`merge`/`lerp`.
- `GlassShape`: superellipse / relative / capsule / circle / rect outlines.
- `Container`-style sizing (wrap child + padding, expand childless), with
  `padding`, `alignment`, and `clipBehavior`; pane hit-tests its exact shape.
- `AnimatedLiquidGlassContainer`: implicit animation of size and settings.
- `GlassRenderMode` (`auto` / `capture` / `backdropFilter`) with
  `renderModeOf`/`settingsOf` inherited lookups.
- Hashed backdrop capture: zero per-frame rasterizations over a static
  backdrop, per-container crops on animated backdrops.
- Glass-through-glass compositing for overlapping panes, children included.
- BackdropFilter-based fallback on CanvasKit (dart2js) web builds.
