# 0.1.4

- `--wasm` (skwasm) web builds no longer crash with glass stacked over
  glass on a changing backdrop. Skwasm rasterizes a `toImageSync` image the
  first time it is drawn, and each pane built its blur and its composite
  from other such images, so one frame nested about three rasterizations
  per stacked pane and overflowed skwasm's 64 KB stack, multi- or
  single-threaded. The overflow silently corrupted memory until a later
  call failed ("table index is out of bounds", "memory access out of
  bounds", "Aborted()") or hung. On skwasm every texture is now recorded
  straight from the backdrop's pictures: one level per pane.
- On skwasm, a pane with `blurEdge` on and a blur above 2 device px no
  longer builds a sharp backdrop texture, and the scope's shared sharp
  texture is built only for panes that show it. On a scope under about
  200 device px tall, the anti-aliased edge of such a pane now shows the
  blurred backdrop instead of the sharp one.
- On Impeller, a pane's backdrop blur of 4 device px or more was 2-4x too
  weak (lower panes read crisp, text under a rim smeared into stripes); it
  now matches Skia.
- Glass stacked over glass: a lower pane under `Opacity` or
  `ColorFiltered` reads faded or filtered through an upper pane, as it
  does on screen; a lower pane inside a clean repaint boundary stays in an
  upper pane's composite across scope repaints; and an upper pane arriving
  over a pane in a clean repaint boundary now shows it.
- The shader no longer flips the backdrop textures vertically on Impeller's
  OpenGL ES backend.

# 0.1.3

- Panes under a scale transform (`Transform.scale`, `FittedBox`, or a scale
  anywhere between the pane and its scope) refract the backdrop where they are
  drawn. The shader mapped each fragment's pane-local offset to the backdrop
  unscaled, so a pane at 0.7 showed content from 1/0.7 as far away: ghosts of
  nearby controls inside the glass and a horizon at the wrong height. Lengths
  local to the pane (refraction reach, blur radius) now scale with it.
- Glass stacked on a scaled pane composites it at the scaled size. The capture
  walk registered panes from the repaint boundary and follower translations
  only, ignoring transforms pushed on the canvas, and recorded the lower
  pane's glass and child at full size, so an upper pane (a menu, a settings
  panel, drag feedback) showed the pane below oversized and shifted.
- Output under translation-only transforms is unchanged. Rotation, skew, and
  mirroring stay unsupported.

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
