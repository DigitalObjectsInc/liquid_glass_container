# 0.1.2

- `CompositedTransformFollower` content (dropdown menus, text selection
  handles, anything anchored to a `CompositedTransformTarget`) is captured
  inline with the transform it was last composited with, instead of at its
  own layout offset and poisoning the frame hash. A follower inside a
  capture-mode `GlassBackdropScope` now refracts where it shows on screen,
  and no longer forces a recapture and re-raster on every frame for as long
  as it stands (seen as a scope wrapping the `Navigator` never settling while
  a `TextField` in an overlay was focused). A follower that moves with its
  leader is picked up by the post-frame watcher, one frame late.

# 0.1.1

- Fix editable text (and any subtree behind a `CompositedTransformTarget`,
  `CompositedTransformFollower`, or `ShaderMask`) rendering displaced on screen
  while inside a capture-mode `GlassBackdropScope`. The backdrop capture walk
  ran the render objects' paint with scope-relative offsets, and paints that
  mutate their retained live layer in place (`LeaderLayer.offset`,
  `ShaderMaskLayer.maskRect`, ...) left those offsets in the live layer tree,
  which a clean repaint boundary then re-composited as-is. The capture now
  hides a render object's retained layer for the duration of its paint, so the
  paint builds a throwaway instead and the live layer is never touched. Seen
  as "blank/displaced `TextField`" on skwasm, but present on every target in
  capture mode (CanvasKit defaults to the `BackdropFilter` fallback).
- Fix repaint boundaries being captured at their scope offset instead of at
  `Offset.zero` under a translation, as the framework paints them. Boundaries
  that draw at the canvas origin (`RenderEditable`'s caret and selection
  painters) were displaced inside the refraction.
- Composition callbacks registered during the capture walk
  (`EditableText`'s IME size/transform updates) are routed to the scope's
  live layer instead of the off-screen capture layer.
- `LeaderLayer` content is captured inline with its offset instead of
  poisoning the frame hash, so a focused `TextField` under glass no longer
  forces a recapture and re-raster on every frame.
- `GlassRenderMode.auto` is documented per target: `capture` everywhere,
  including `--wasm` (skwasm) web builds; `backdropFilter` only on
  JavaScript (CanvasKit) web builds.

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
  `padding`, `alignment`, and `clipBehavior`; intrinsics, dry layout, and
  baselines included; pane hit-tests its exact shape.
- `AnimatedLiquidGlassContainer`: implicit animation of size and settings.
- `GlassRenderMode` (`auto` / `capture` / `backdropFilter`) with
  `renderModeOf`/`settingsOf` inherited lookups.
- Hashed backdrop capture: zero per-frame rasterizations over a static
  backdrop, per-container crops on animated backdrops; descendant repaint
  boundaries (scrolling lists, `FadeTransition`s) tracked via layer
  signatures.
- Glass-through-glass compositing for overlapping panes, children included.
- BackdropFilter-based fallback on CanvasKit (dart2js) web builds.
