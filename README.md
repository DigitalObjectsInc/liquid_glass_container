# liquid_glass_container

Liquid glass for Flutter — real refraction, chromatic dispersion, fresnel, glare, backdrop blur, tint, superellipse corners, and drop shadow, rendered in a single fragment-shader draw per pane. A Flutter port of [liquid-glass-studio](https://github.com/iyinchao/liquid-glass-studio)'s WebGL effect (final STEP 9 composite). One implementation for iOS, Android, desktop, and web.

## Usage

Wrap the app (or any subtree) once, then drop containers anywhere below it:

```dart
import 'package:liquid_glass_container/liquid_glass_container.dart';

GlassBackdropScope(
  settings: const LiquidGlassSettings(blurRadius: 10),   // optional, inherited by all panes
  child: Stack(children: [
    background,
    Center(
      child: LiquidGlassContainer(
        padding: const EdgeInsets.all(24),
        child: Text('Hello'),                            // pane wraps its child
      ),
    ),
  ]),
)
```

Optional: `await LiquidGlassContainer.precache()` before the first build to avoid a blank first frame (when calling it before `runApp`, call `WidgetsFlutterBinding.ensureInitialized()` first).

### Sizing

`LiquidGlassContainer` sizes like `Container`: explicit `width`/`height` win; otherwise the pane wraps its `child` plus `padding`, or expands to the incoming constraints when childless. The child is placed at `alignment` (default center) inside the padded pane and painted on top of the glass: its own pane never refracts or blurs it, but a pane stacked on top samples it like any other content below. `clipBehavior` clips the child to the glass shape.

The pane hit-tests its exact outline: touches inside the superellipse are absorbed (so `GestureDetector`/buttons on glass behave), corners outside it pass through.

### Settings

Visuals live in `LiquidGlassSettings`, an immutable value class where **every field is nullable and null means inherit**. Resolution is field-wise: package defaults ← `GlassBackdropScope.settings` ← the container's own `settings`. A pane that only wants more blur passes exactly that:

```dart
LiquidGlassContainer(
  settings: const LiquidGlassSettings(blurRadius: 40),  // everything else from the scope
)
```

`copyWith`, `merge`, and `lerp` are provided; `GlassBackdropScope.settingsOf(context)` returns the fully resolved inherited settings. `AnimatedLiquidGlassContainer` implicitly animates size, padding, alignment, and every settings field.

| Field | Default | Meaning |
|---|---|---|
| `shape` | relative superellipse, factor 0.8, roundness 5 | Pane outline: `GlassShape.superellipse` (radius in logical px), `.relative` (fraction of half the short side), `.capsule()`, `.circle()`, `.rect()`; `roundness` is the corner exponent, 2 (round) .. 7 (squircle) |
| `thickness` | 20 | Refraction band depth, logical px |
| `indexOfRefraction` | 1.4 | 1 (none) .. ~2.5 |
| `dispersion` | 7 | Chromatic dispersion, 0 .. 50 |
| `fresnelRange` / `fresnelHardness` / `fresnelIntensity` | 30 / 0.2 / 0.2 | Fresnel rim light (hardness/intensity 0..1) |
| `glareRange` / `glareHardness` / `glareIntensity` / `glareConvergence` / `glareOppositeIntensity` / `glareAngle` | 30 / 0.2 / 0.9 / 0.5 / 0.8 / -π/4 | Specular glare band (angle in radians) |
| `blurRadius` | 1 | Backdrop blur radius, logical px |
| `blurEdge` | true | Blur reaches into the refraction band |
| `tint` | transparent | LCH-blended tint color |
| `shadowBlur` / `shadowIntensity` / `shadowOffset` | 25 / 0.15 / (0, 10) | Drop + interior shadow (offset y-down) |

All units follow Flutter conventions (logical px, 0..1 fractions, radians, y-down offsets). To transfer settings from [liquid-glass-studio](https://iyinchao.github.io/liquid-glass-studio/)'s control panel: divide its 0..100 knobs by 100, convert `glareAngle` degrees to radians, divide its device-px blur radius by your devicePixelRatio, and flip the shadow position's y sign (the reference is y-up).

## How it works

When the scope's subtree repaints, the scope re-records the backdrop (glass excluded) through a command-hashing canvas; the retained capture and its generation counter only change when the recorded content actually differs, so glass moving over a static backdrop reuses the previous capture. Each container caches a crop of that capture (sharp + Skia-gaussian-blurred, downscaled at large radii) keyed on generation and a grid-quantized crop rect, and composites the glass in one fragment-shader draw straight into the frame (`glass_main.frag`: refraction, dispersion, fresnel, glare, analytic interior shadow, LCH color math from the reference). The outer drop shadow is a mask-filtered superellipse path; edge anti-aliasing comes from a matching clip.

Overlapping containers see each other: the scope keeps a paint-order registry of glass rects, and a pane overlapped from below composites the lower panes' recorded output (shadow and child included) into its backdrop textures before refracting — real stacked glass, in paint order. This costs one extra crop rasterization per overlapped pane whenever any glass geometry/parameter or sampled child content changes, and nothing when panes don't overlap.

The pipeline minimizes `toImageSync` rasterizations and adapts to how the backdrop behaves. Static backdrop: one shared full-scope texture set (sharp + one blurred per distinct blur radius), position independent — glass can move and animate with zero rasterizations per frame, and every container samples the same textures. Animated backdrop (content changing on consecutive frames): each container rasterizes only a grid-quantized crop around itself, so readback bytes track the glass area, not the window.

## Render modes

`GlassBackdropScope.renderMode` selects the strategy; `GlassRenderMode.auto` (default) resolves per platform. `GlassBackdropScope.renderModeOf(context)` returns the resolved mode, so apps can adapt to the fallback's missing effects.

On CanvasKit, every `toImageSync` is a synchronous GPU readback, which makes the capture pipeline slow there — and the default web loader serves the CanvasKit build to Safari and Firefox, even with `--wasm`. On CanvasKit builds (`kIsWeb && !kIsWasm`) `auto` therefore resolves to `GlassRenderMode.backdropFilter`: the scope skips capture completely and each container paints as one clipped `BackdropFilter` plus one shader draw:

- Backdrop blur replaces the blurred texture. A magnifying `ImageFilter.matrix` approximates refraction as a uniform lens.
- `glass_overlay.frag` draws fresnel, glare, interior shadow, and tint on top.
- The drop shadow paints outside the shape only; the overlay owns the interior term.

Lower panes are already in the backdrop when an upper pane samples it, so glass-through-glass still works. Not reproduced in the fallback: chromatic dispersion, `blurEdge: false`, and the backdrop-derived glare color. `GlassRenderMode.backdropFilter` can also be forced on any backend for comparison or debugging.

Measured in Chrome CanvasKit, 1200×900, 5 panes, profile build: fallback ~18 ms/frame, identical for static and animated backdrops; the capture pipeline measures 23–58 ms there. On skwasm and native backends the capture pipeline runs well under frame budget.

## Constraints

- Containers must be descendants of the scope, with translation-only transforms between them (no rotation/scale of the pane itself). Scopes must not be nested (asserts in debug).
- Backdrops containing platform views, textures, custom layers, or `FragmentShader` paints disable capture reuse (the scope recaptures every repaint — correct, just less cheap).
- A pane's `child` is visible through panes stacked on top of it, except child content drawn via platform views or textures (it can't be recorded into the composite, so it is omitted from the upper pane's refraction).
- Known deviations from the reference: blur via Skia's `ImageFilter.blur` (same sigma = radius/3) instead of the two-pass shader; drop shadow is a gaussian approximation of the exponential falloff; edge blend is clip AA instead of an SDF smoothstep; RGBA8 intermediates vs RGBA16F.

## Example

`example/` is a full playground: background/implementation chips, a control panel with every parameter (feeding scope-level settings, so the panes carry none), and cursor-follow glass with the reference's spring physics. Web measurement knobs: `?impl=full|fb`, `?bg=anim` (scrolling backdrop), `?auto` (self-driving glass); profile builds print frame timings every 120 frames.

## Credits

Shader math and visual design ported from [liquid-glass-studio](https://github.com/iyinchao/liquid-glass-studio) by Charles Yin (MIT). This package reimplements the compositing pipeline for Flutter's raster model.
