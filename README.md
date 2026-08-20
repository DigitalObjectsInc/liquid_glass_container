# liquid_glass_container

Liquid glass for Flutter — real refraction, chromatic dispersion, fresnel, glare, backdrop blur, tint, superellipse corners, and drop shadow, rendered in a single fragment-shader draw per pane. A Flutter port of [liquid-glass-studio](https://github.com/iyinchao/liquid-glass-studio)'s WebGL effect (final STEP 9 composite). One implementation for iOS, Android, desktop, and web.

## Usage

Wrap the app (or any subtree) once, then drop containers anywhere below it:

```dart
import 'package:liquid_glass_container/liquid_glass_container.dart';

GlassBackdropScope(
  child: Stack(children: [
    background,
    Center(
      child: LiquidGlassContainer(          // all knobs optional, reference defaults
        width: 260,
        height: 160,
        child: Text('Hello'),               // optional, laid out centered on the pane
      ),
    ),
  ]),
)
```

`LiquidGlassContainer` exposes every reference control (thickness, IOR, dispersion, fresnel, glare, blur radius, tint, shadow, superellipse corners) with the reference's names, scales, and defaults. Optional: `await LiquidGlassContainer.precache()` before the first build to avoid a blank first frame.

The `child` is painted on top of the glass and never enters the backdrop, so it is not refracted or blurred. It gets loose constraints and is centered; wrap it in `Align`/`Padding` for other placements.

### Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `width`, `height` | 200 | Pane size (logical px), constrained by the parent |
| `cornerRadius` | 80 | % of `min(width, height) / 2` |
| `roundness` | 5 | Superellipse corner exponent, 2 (round) .. 7 (squircle) |
| `refThickness` | 20 | Refraction band depth |
| `refFactor` | 1.4 | Index of refraction, 1 .. 2.5 |
| `refDispersion` | 7 | Chromatic dispersion, 0 .. 50 |
| `refFresnelRange` / `refFresnelHardness` / `refFresnelFactor` | 30 / 20 / 20 | Fresnel rim light |
| `glareRange` / `glareHardness` / `glareFactor` / `glareConvergence` / `glareOppositeFactor` / `glareAngle` | 30 / 20 / 90 / 50 / 80 / -45° | Specular glare band |
| `blurRadius` | 1 | Backdrop blur radius, device px, 1 .. 200 |
| `blurEdge` | true | Blur reaches into the refraction band |
| `tint` | transparent | LCH-blended tint color |
| `shadowExpand` / `shadowFactor` / `shadowPosition` | 25 / 15 / (0, -10) | Drop + interior shadow |

Parameter names, scales, and defaults mirror the reference's control panel, so settings found in [liquid-glass-studio](https://iyinchao.github.io/liquid-glass-studio/) transfer 1:1.

## How it works

When the scope's subtree repaints, the scope re-records the backdrop (glass excluded) through a command-hashing canvas; the retained capture and its generation counter only change when the recorded content actually differs, so glass moving over a static backdrop reuses the previous capture. Each container caches a crop of that capture (sharp + Skia-gaussian-blurred, downscaled at large radii) keyed on generation and a grid-quantized crop rect, and composites the glass in one fragment-shader draw straight into the frame (`glass_main.frag`: refraction, dispersion, fresnel, glare, analytic interior shadow, LCH color math from the reference). The outer drop shadow is a mask-filtered superellipse path; edge anti-aliasing comes from a matching clip.

Overlapping containers see each other: the scope keeps a paint-order registry of glass rects, and a pane overlapped from below composites the lower panes' recorded output (shadow included) into its backdrop textures before refracting — real stacked glass, in paint order. This costs one extra crop rasterization per overlapped pane whenever any glass geometry/parameter changes, and nothing when panes don't overlap.

The pipeline minimizes `toImageSync` rasterizations and adapts to how the backdrop behaves. Static backdrop: one shared full-scope texture set (sharp + one blurred per distinct blur radius), position independent — glass can move and animate with zero rasterizations per frame, and every container samples the same textures. Animated backdrop (content changing on consecutive frames): each container rasterizes only a grid-quantized crop around itself, so readback bytes track the glass area, not the window.

## CanvasKit fallback

On CanvasKit, every `toImageSync` is a synchronous GPU readback, which makes the capture pipeline slow there — and the default web loader serves the CanvasKit build to Safari and Firefox, even with `--wasm`.

On CanvasKit builds (`kIsWeb && !kIsWasm`) the scope therefore skips capture completely. Each container paints as one clipped `BackdropFilter` plus one shader draw:

- Backdrop blur replaces the blurred texture. A magnifying `ImageFilter.matrix` approximates refraction as a uniform lens.
- `glass_overlay.frag` draws fresnel, glare, interior shadow, and tint on top.
- The drop shadow paints outside the shape only; the overlay owns the interior term.

Lower panes are already in the backdrop when an upper pane samples it, so glass-through-glass still works. Not reproduced in the fallback: chromatic dispersion, `blurEdge: false`, and the backdrop-derived glare color.

`GlassBackdropScope` flags: `fallbackOnCanvasKit` (default true) switches automatically; `forceFallback` (default false) uses the fallback on every backend, for comparison or debugging.

Measured in Chrome CanvasKit, 1200×900, 5 panes, profile build: fallback ~18 ms/frame, identical for static and animated backdrops; the capture pipeline measures 23–58 ms there. On skwasm and native backends the capture pipeline runs well under frame budget.

## Constraints

- Containers must be descendants of the scope, with translation-only transforms between them (no rotation/scale of the pane itself).
- Backdrops containing platform views, textures, custom layers, or `FragmentShader` paints disable capture reuse (the scope recaptures every repaint — correct, just less cheap).
- A pane's `child` is not visible through another pane stacked on top of it (only the glass surfaces composite through).
- Known deviations from the reference: blur via Skia's `ImageFilter.blur` (same sigma = radius/3) instead of the two-pass shader; drop shadow is a gaussian approximation of the exponential falloff; edge blend is clip AA instead of an SDF smoothstep; RGBA8 intermediates vs RGBA16F.

## Example

`example/` is a full playground: background/implementation chips, a control panel with every parameter, and cursor-follow glass with the reference's spring physics. Web measurement knobs: `?impl=full|fb`, `?bg=anim` (scrolling backdrop), `?auto` (self-driving glass); profile builds print frame timings every 120 frames.

## Credits

Shader math and visual design ported from [liquid-glass-studio](https://github.com/iyinchao/liquid-glass-studio) by Charles Yin (MIT). This package reimplements the compositing pipeline for Flutter's raster model.
