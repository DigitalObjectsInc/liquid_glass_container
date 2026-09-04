import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'settings.dart';

/// Loads the fragment programs once, shared by all containers.
class _GlassShaders {
  static late ui.FragmentProgram main;
  static late ui.FragmentProgram overlay;
  static Future<void>? _loading;

  static bool loaded = false;

  /// Set when loading failed (reported once via [FlutterError.reportError]);
  /// containers then paint their children without glass instead of retrying.
  static bool failed = false;

  // Consumers address package shaders as packages/<pkg>/lib/... (the shaders
  // section keeps the full lib/ path, unlike images); when this package itself
  // is the root project (its own `flutter test`) the key is the raw lib/ path,
  // hence the fallback. If both fail, the packages/ error is the one relevant
  // to consumers, so it is the one rethrown.
  static Future<ui.FragmentProgram> _load(String name) async {
    try {
      return await ui.FragmentProgram.fromAsset(
        'packages/liquid_glass_container/lib/shaders/$name',
      );
    } on Object catch (e, s) {
      try {
        return await ui.FragmentProgram.fromAsset('lib/shaders/$name');
      } on Object {
        Error.throwWithStackTrace(e, s);
      }
    }
  }

  /// Never completes with an error: a load failure is reported to
  /// [FlutterError] and latched in [failed], so per-paint listeners don't
  /// turn one failure into a stream of unhandled async errors.
  static Future<void> ensureLoaded() => _loading ??=
      Future.wait([_load('glass_main.frag'), _load('glass_overlay.frag')])
          .then((ps) {
            main = ps[0];
            overlay = ps[1];
            loaded = true;
            _warmUp();
          })
          .catchError((Object e, StackTrace s) {
            failed = true;
            FlutterError.reportError(
              FlutterErrorDetails(
                exception: e,
                stack: s,
                library: 'liquid_glass_container',
                context: ErrorDescription(
                  'while loading the liquid glass shader programs',
                ),
              ),
            );
          });

  /// Draw 1px with each program so the GPU compiles/links them at load time
  /// rather than on the first interaction (WebGL compiles lazily on first use).
  static void _warmUp() {
    final rec = ui.PictureRecorder();
    Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 1, 1), Paint());
    final pic = rec.endRecording();
    final dummy = pic.toImageSync(1, 1);
    pic.dispose();
    final s = main.fragmentShader();
    s.setImageSampler(0, dummy);
    s.setImageSampler(1, dummy);
    final o = overlay.fragmentShader();
    final r = ui.PictureRecorder();
    Canvas(r)
      ..drawRect(const Rect.fromLTWH(0, 0, 1, 1), Paint()..shader = s)
      ..drawRect(const Rect.fromLTWH(0, 0, 1, 1), Paint()..shader = o);
    final p = r.endRecording();
    p.toImageSync(1, 1).dispose();
    p.dispose();
    s.dispose();
    o.dispose();
    dummy.dispose();
  }
}

/// Order-insensitive-collision-resistant-enough accumulator for the backdrop
/// recording. Two independent 30-bit Jenkins lanes (web-safe integer math);
/// a collision would show a stale backdrop, so ~60 bits keeps that negligible.
class _FrameHasher {
  int _a = 0x243f6a88; // pi fractional bits, arbitrary distinct seeds
  int _b = 0x85a308d3;
  bool poisoned = false;

  void poison() => poisoned = true;

  static int _mix(int h, int v) {
    h = 0x3fffffff & (h + v);
    h = 0x3fffffff & (h + ((0x0003ffff & h) << 10));
    return h ^ (h >> 6);
  }

  void addInt(int v) {
    _a = _mix(_a, v);
    _b = _mix(_b, v ^ 0x9e3779b9);
  }

  void addDouble(double v) => addInt(v.hashCode);

  bool sameAs(int a, int b) => _a == a && _b == b;
  int get a => _a;
  int get b => _b;
}

/// Canvas proxy that folds every draw command into the frame hash so the
/// scope can tell whether the backdrop recording actually changed. Objects
/// with value equality fold their hashCode. Paths fold a content heuristic
/// (fill type, bounds, per-contour length and midpoint tangent): a mutation
/// that keeps all of those equal would go unseen, which is accepted. Other
/// objects (images, shaders) fold by identity and can only false-mismatch,
/// which costs a recapture. Mutable-without-identity cases (FragmentShader
/// uniforms) poison the hash instead.
class _HashingCanvas implements Canvas {
  _HashingCanvas(this._c, this._h);

  final Canvas _c;
  final _FrameHasher _h;

  void _i(int v) => _h.addInt(v);
  void _d(double v) => _h.addDouble(v);
  void _off(Offset o) {
    _d(o.dx);
    _d(o.dy);
  }

  void _rect(Rect r) {
    _d(r.left);
    _d(r.top);
    _d(r.right);
    _d(r.bottom);
  }

  void _rrect(RRect r) {
    _i(r.hashCode);
  }

  // Content hash. Identity is unusable in both directions: the framework
  // shifts a fresh Path per paint (PhysicalShape, pushClipPath), which would
  // force a recapture every frame, and a painter can mutate one Path in
  // place, which would freeze the capture. Fold fill type, bounds, and per
  // contour the length, closedness, and midpoint tangent.
  void _path(Path p) {
    _i(p.fillType.index);
    _rect(p.getBounds());
    var n = 0;
    for (final m in p.computeMetrics()) {
      n++;
      _d(m.length);
      _i(m.isClosed ? 1 : 0);
      if (m.length > 0) {
        final t = m.getTangentForOffset(m.length / 2);
        if (t != null) {
          _off(t.position);
          _d(t.angle);
        }
      }
    }
    _i(n);
  }

  void _img(ui.Image i) => _i(identityHashCode(i));

  void _paint(Paint p) {
    _i(p.color.hashCode);
    _i(p.blendMode.index);
    _i(p.style.index);
    _d(p.strokeWidth);
    _i(p.strokeCap.index);
    _i(p.strokeJoin.index);
    _d(p.strokeMiterLimit);
    _i(p.isAntiAlias ? 1 : 0);
    _i(p.invertColors ? 3 : 2);
    _i(p.filterQuality.index);
    final shader = p.shader;
    if (shader != null) {
      // uniforms can be mutated in place with no observable identity change
      if (shader is ui.FragmentShader) _h.poison();
      _i(identityHashCode(shader));
    }
    _i(p.maskFilter?.hashCode ?? 0);
    _i(p.colorFilter?.hashCode ?? 0);
    _i(p.imageFilter?.hashCode ?? 0);
  }

  void _f32(Float32List? l) {
    if (l == null) return _i(0);
    _i(l.length);
    for (final v in l) {
      _d(v);
    }
  }

  @override
  void save() {
    _i(1);
    _c.save();
  }

  @override
  void saveLayer(Rect? bounds, Paint paint) {
    _i(2);
    if (bounds != null) _rect(bounds);
    _paint(paint);
    _c.saveLayer(bounds, paint);
  }

  @override
  void restore() {
    _i(3);
    _c.restore();
  }

  @override
  void restoreToCount(int count) {
    _i(4);
    _i(count);
    _c.restoreToCount(count);
  }

  @override
  int getSaveCount() => _c.getSaveCount();

  @override
  void translate(double dx, double dy) {
    _i(5);
    _d(dx);
    _d(dy);
    _c.translate(dx, dy);
  }

  @override
  void scale(double sx, [double? sy]) {
    _i(6);
    _d(sx);
    _d(sy ?? sx);
    _c.scale(sx, sy);
  }

  @override
  void rotate(double radians) {
    _i(7);
    _d(radians);
    _c.rotate(radians);
  }

  @override
  void skew(double sx, double sy) {
    _i(8);
    _d(sx);
    _d(sy);
    _c.skew(sx, sy);
  }

  @override
  void transform(Float64List matrix4) {
    _i(9);
    for (final v in matrix4) {
      _d(v);
    }
    _c.transform(matrix4);
  }

  @override
  Float64List getTransform() => _c.getTransform();

  @override
  void clipRect(
    Rect rect, {
    ui.ClipOp clipOp = ui.ClipOp.intersect,
    bool doAntiAlias = true,
  }) {
    _i(10);
    _rect(rect);
    _i(clipOp.index);
    _i(doAntiAlias ? 1 : 0);
    _c.clipRect(rect, clipOp: clipOp, doAntiAlias: doAntiAlias);
  }

  @override
  void clipRRect(RRect rrect, {bool doAntiAlias = true}) {
    _i(11);
    _rrect(rrect);
    _i(doAntiAlias ? 1 : 0);
    _c.clipRRect(rrect, doAntiAlias: doAntiAlias);
  }

  @override
  void clipRSuperellipse(
    ui.RSuperellipse rsuperellipse, {
    bool doAntiAlias = true,
  }) {
    _i(12);
    _i(rsuperellipse.hashCode);
    _i(doAntiAlias ? 1 : 0);
    _c.clipRSuperellipse(rsuperellipse, doAntiAlias: doAntiAlias);
  }

  @override
  void clipPath(Path path, {bool doAntiAlias = true}) {
    _i(13);
    _path(path);
    _i(doAntiAlias ? 1 : 0);
    _c.clipPath(path, doAntiAlias: doAntiAlias);
  }

  @override
  Rect getLocalClipBounds() => _c.getLocalClipBounds();

  @override
  Rect getDestinationClipBounds() => _c.getDestinationClipBounds();

  @override
  void drawColor(Color color, BlendMode blendMode) {
    _i(14);
    _i(color.hashCode);
    _i(blendMode.index);
    _c.drawColor(color, blendMode);
  }

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) {
    _i(15);
    _off(p1);
    _off(p2);
    _paint(paint);
    _c.drawLine(p1, p2, paint);
  }

  @override
  void drawPaint(Paint paint) {
    _i(16);
    _paint(paint);
    _c.drawPaint(paint);
  }

  @override
  void drawRect(Rect rect, Paint paint) {
    _i(17);
    _rect(rect);
    _paint(paint);
    _c.drawRect(rect, paint);
  }

  @override
  void drawRRect(RRect rrect, Paint paint) {
    _i(18);
    _rrect(rrect);
    _paint(paint);
    _c.drawRRect(rrect, paint);
  }

  @override
  void drawDRRect(RRect outer, RRect inner, Paint paint) {
    _i(19);
    _rrect(outer);
    _rrect(inner);
    _paint(paint);
    _c.drawDRRect(outer, inner, paint);
  }

  @override
  void drawRSuperellipse(ui.RSuperellipse rsuperellipse, Paint paint) {
    _i(20);
    _i(rsuperellipse.hashCode);
    _paint(paint);
    _c.drawRSuperellipse(rsuperellipse, paint);
  }

  @override
  void drawOval(Rect rect, Paint paint) {
    _i(21);
    _rect(rect);
    _paint(paint);
    _c.drawOval(rect, paint);
  }

  @override
  void drawCircle(Offset c, double radius, Paint paint) {
    _i(22);
    _off(c);
    _d(radius);
    _paint(paint);
    _c.drawCircle(c, radius, paint);
  }

  @override
  void drawArc(
    Rect rect,
    double startAngle,
    double sweepAngle,
    bool useCenter,
    Paint paint,
  ) {
    _i(23);
    _rect(rect);
    _d(startAngle);
    _d(sweepAngle);
    _i(useCenter ? 1 : 0);
    _paint(paint);
    _c.drawArc(rect, startAngle, sweepAngle, useCenter, paint);
  }

  @override
  void drawPath(Path path, Paint paint) {
    _i(24);
    _path(path);
    _paint(paint);
    _c.drawPath(path, paint);
  }

  @override
  void drawImage(ui.Image image, Offset offset, Paint paint) {
    _i(25);
    _img(image);
    _off(offset);
    _paint(paint);
    _c.drawImage(image, offset, paint);
  }

  @override
  void drawImageRect(ui.Image image, Rect src, Rect dst, Paint paint) {
    _i(26);
    _img(image);
    _rect(src);
    _rect(dst);
    _paint(paint);
    _c.drawImageRect(image, src, dst, paint);
  }

  @override
  void drawImageNine(ui.Image image, Rect center, Rect dst, Paint paint) {
    _i(27);
    _img(image);
    _rect(center);
    _rect(dst);
    _paint(paint);
    _c.drawImageNine(image, center, dst, paint);
  }

  @override
  void drawPicture(ui.Picture picture) {
    _i(28);
    _i(identityHashCode(picture));
    _c.drawPicture(picture);
  }

  @override
  void drawParagraph(ui.Paragraph paragraph, Offset offset) {
    _i(29);
    // identity + layout metrics: layout() can mutate a paragraph in place
    _i(identityHashCode(paragraph));
    _d(paragraph.width);
    _d(paragraph.height);
    _d(paragraph.longestLine);
    _off(offset);
    _c.drawParagraph(paragraph, offset);
  }

  @override
  void drawPoints(ui.PointMode pointMode, List<Offset> points, Paint paint) {
    _i(30);
    _i(pointMode.index);
    _i(points.length);
    for (final p in points) {
      _off(p);
    }
    _paint(paint);
    _c.drawPoints(pointMode, points, paint);
  }

  @override
  void drawRawPoints(ui.PointMode pointMode, Float32List points, Paint paint) {
    _i(31);
    _i(pointMode.index);
    _f32(points);
    _paint(paint);
    _c.drawRawPoints(pointMode, points, paint);
  }

  @override
  void drawVertices(ui.Vertices vertices, BlendMode blendMode, Paint paint) {
    _i(32);
    _i(identityHashCode(vertices));
    _i(blendMode.index);
    _paint(paint);
    _c.drawVertices(vertices, blendMode, paint);
  }

  @override
  void drawAtlas(
    ui.Image atlas,
    List<RSTransform> transforms,
    List<Rect> rects,
    List<Color>? colors,
    BlendMode? blendMode,
    Rect? cullRect,
    Paint paint,
  ) {
    _i(33);
    _img(atlas);
    _i(transforms.length);
    for (final t in transforms) {
      _d(t.scos);
      _d(t.ssin);
      _d(t.tx);
      _d(t.ty);
    }
    for (final r in rects) {
      _rect(r);
    }
    if (colors != null) {
      for (final c in colors) {
        _i(c.hashCode);
      }
    }
    _i(blendMode?.index ?? -1);
    if (cullRect != null) _rect(cullRect);
    _paint(paint);
    _c.drawAtlas(atlas, transforms, rects, colors, blendMode, cullRect, paint);
  }

  @override
  void drawRawAtlas(
    ui.Image atlas,
    Float32List rstTransforms,
    Float32List rects,
    Int32List? colors,
    BlendMode? blendMode,
    Rect? cullRect,
    Paint paint,
  ) {
    _i(34);
    _img(atlas);
    _f32(rstTransforms);
    _f32(rects);
    if (colors != null) {
      for (final c in colors) {
        _i(c);
      }
    }
    _i(blendMode?.index ?? -1);
    if (cullRect != null) _rect(cullRect);
    _paint(paint);
    _c.drawRawAtlas(
      atlas,
      rstTransforms,
      rects,
      colors,
      blendMode,
      cullRect,
      paint,
    );
  }

  @override
  void drawShadow(
    Path path,
    Color color,
    double elevation,
    bool transparentOccluder,
  ) {
    _i(35);
    _path(path);
    _i(color.hashCode);
    _d(elevation);
    _i(transparentOccluder ? 1 : 0);
    _c.drawShadow(path, color, elevation, transparentOccluder);
  }

  // Canvas members added by future Flutter versions land here instead of
  // breaking every consumer's compile. The draw is omitted from the capture
  // (the screen is unaffected: this canvas only feeds the backdrop
  // recording) and the poison forces a recapture every frame.
  @override
  dynamic noSuchMethod(Invocation invocation) {
    _h.poison();
    return null;
  }
}

/// PaintingContext for the backdrop capture: skips glass containers (they are
/// the consumers of the capture, not part of it), records everything else
/// through a [_HashingCanvas] for change detection, and inlines repaint
/// boundaries and common layer effects so the capture is a self-contained
/// recording that never borrows layers from the live tree.
class _GlassCaptureContext extends PaintingContext {
  _GlassCaptureContext(
    super.layer,
    super.bounds,
    this._hasher,
    this._scope, {
    this.registerGlass = true,
  });

  final _FrameHasher _hasher;
  final RenderGlassScope _scope;

  /// False while recording a pane's child: nested glass is skipped silently
  /// instead of registered (the registry is built by the main capture walk).
  final bool registerGlass;

  Canvas? _inner;
  _HashingCanvas? _wrapped;

  @override
  Canvas get canvas {
    final inner = super.canvas;
    if (!identical(inner, _inner)) {
      _inner = inner;
      _wrapped = _HashingCanvas(inner, _hasher);
    }
    return _wrapped!;
  }

  @override
  PaintingContext createChildContext(ContainerLayer childLayer, Rect bounds) =>
      _GlassCaptureContext(
        childLayer,
        bounds,
        _hasher,
        _scope,
        registerGlass: registerGlass,
      );

  @override
  void paintChild(RenderObject child, Offset offset) {
    if (child is RenderLiquidGlassContainer) {
      // Glass never enters the backdrop, but the visit builds the paint-order
      // registry that drives glass-through-glass compositing.
      if (registerGlass) _scope._registerGlass(child, offset);
      return;
    }
    if (child.isRepaintBoundary) {
      // Inline the subtree instead of adopting its retained layer: keeps the
      // capture self-contained and lets the hash see the actual content. The
      // boundary is tracked so the scope's post-frame watcher can detect its
      // independent repaints (which never mark the scope dirty).
      _scope._boundaries.add(child);
      _hasher.addInt(36);
      _hasher.addDouble(offset.dx);
      _hasher.addDouble(offset.dy);
      // Effects a boundary applies through its composited layer
      // (updateCompositedLayer) don't run when its paint is inlined; recreate
      // the common ones. Null on the boundary's very first frame (it hasn't
      // composited yet): painted plain, converged by the watcher next frame.
      // ignore: invalid_use_of_protected_member
      final boundaryLayer = child.layer;
      if (boundaryLayer == null) _scope._sawUncomposited = true;
      if (boundaryLayer is OpacityLayer) {
        final alpha = boundaryLayer.alpha ?? 255;
        _hasher.addInt(alpha);
        canvas.saveLayer(null, Paint()..color = Color.fromARGB(alpha, 0, 0, 0));
        child.paint(this, offset);
        canvas.restore();
      } else if (boundaryLayer is ImageFilterLayer &&
          boundaryLayer.imageFilter != null) {
        _hasher.addInt(identityHashCode(boundaryLayer.imageFilter));
        canvas.saveLayer(null, Paint()..imageFilter = boundaryLayer.imageFilter);
        child.paint(this, offset);
        canvas.restore();
      } else {
        child.paint(this, offset);
      }
      return;
    }
    super.paintChild(child, offset);
  }

  @override
  void appendLayer(Layer layer) {
    // NEVER adopt a layer into the capture tree. Most layers that reach here
    // are a render object's retained live layer; the default appendLayer
    // calls layer.remove(), which detaches it from the visible tree. A clean
    // repaint boundary then re-composites without it and its content
    // vanishes from the screen. Leaf layers (textures, platform views) also
    // land here: their content cannot enter a flat recording, so it is
    // omitted from the refraction and the poison forces a recapture every
    // frame. Not calling super also keeps the current recording (and its
    // save stack) alive.
    _hasher.poison();
  }

  @override
  void addLayer(Layer layer) {
    // The base method stops the current recording (dropping its save stack,
    // so later siblings would record unclipped) before it appends. Same
    // treatment as appendLayer: poison only, keep the recording alive.
    _hasher.poison();
  }

  @override
  void pushLayer(
    ContainerLayer childLayer,
    PaintingContextCallback painter,
    Offset offset, {
    Rect? childPaintBounds,
  }) {
    // Same rule as appendLayer: never parent or mutate the passed layer.
    // Emulate the common effects inline; the wrapped canvas hashes the
    // emulation parameters (paint color, filters, shader identity).
    if (childLayer is OpacityLayer) {
      final alpha = childLayer.alpha ?? 255;
      canvas.saveLayer(null, Paint()..color = Color.fromARGB(alpha, 0, 0, 0));
      painter(this, offset);
      canvas.restore();
    } else if (childLayer is ColorFilterLayer &&
        childLayer.colorFilter != null) {
      canvas.saveLayer(null, Paint()..colorFilter = childLayer.colorFilter);
      painter(this, offset);
      canvas.restore();
    } else if (childLayer is ImageFilterLayer &&
        childLayer.imageFilter != null) {
      canvas.saveLayer(null, Paint()..imageFilter = childLayer.imageFilter);
      painter(this, offset);
      canvas.restore();
    } else if (childLayer is ShaderMaskLayer &&
        childLayer.shader != null &&
        childLayer.maskRect != null) {
      final maskRect = childLayer.maskRect!;
      canvas.saveLayer(null, Paint());
      painter(this, offset);
      // the shader's origin is maskRect's top-left, not the canvas origin
      canvas.save();
      canvas.translate(maskRect.left, maskRect.top);
      canvas.drawRect(
        Offset.zero & maskRect.size,
        Paint()
          ..shader = childLayer.shader
          ..blendMode = childLayer.blendMode ?? BlendMode.modulate,
      );
      canvas.restore();
      canvas.restore();
    } else if (childLayer is ClipRectLayer && childLayer.clipRect != null) {
      canvas.save();
      canvas.clipRect(childLayer.clipRect!);
      painter(this, offset);
      canvas.restore();
    } else if (childLayer is ClipRRectLayer && childLayer.clipRRect != null) {
      canvas.save();
      canvas.clipRRect(childLayer.clipRRect!);
      painter(this, offset);
      canvas.restore();
    } else if (childLayer is ClipPathLayer && childLayer.clipPath != null) {
      canvas.save();
      canvas.clipPath(childLayer.clipPath!);
      painter(this, offset);
      canvas.restore();
    } else if (childLayer is TransformLayer && childLayer.transform != null) {
      canvas.save();
      canvas.transform(childLayer.transform!.storage);
      painter(this, offset);
      canvas.restore();
    } else if (childLayer is BackdropFilterLayer) {
      // A backdrop effect cannot replay into a flat recording: keep the
      // child content, drop the filter. The backdrop under it is already in
      // the recording, so the hash still tracks every visible change.
      _hasher.addInt(40);
      _hasher.addInt(childLayer.filter?.hashCode ?? 0);
      painter(this, offset);
    } else if (childLayer is AnnotatedRegionLayer) {
      // pure metadata (system chrome, semantics): content only
      painter(this, offset);
    } else {
      // unknown semantics (Leader/Follower, custom layers): keep the
      // content, recapture every frame
      _hasher.poison();
      painter(this, offset);
    }
  }

  @override
  ClipRSuperellipseLayer? pushClipRSuperellipse(
    bool needsCompositing,
    Offset offset,
    Rect bounds,
    RSuperellipse clipRSuperellipse,
    PaintingContextCallback painter, {
    Clip clipBehavior = Clip.antiAlias,
    ClipRSuperellipseLayer? oldLayer,
  }) {
    super.pushClipRSuperellipse(
      false,
      offset,
      bounds,
      clipRSuperellipse,
      painter,
      clipBehavior: clipBehavior,
    );
    return clipBehavior == Clip.none
        ? null
        : ClipRSuperellipseLayer(
            clipRSuperellipse: clipRSuperellipse.shift(offset),
            clipBehavior: clipBehavior,
          );
  }

  // The push* overrides force the non-composited inline path (recorded through
  // the hashing canvas) and hand back a fresh throwaway layer for callers that
  // cache `layer` — it's only ever used as an oldLayer donor afterwards.

  @override
  ClipRectLayer? pushClipRect(
    bool needsCompositing,
    Offset offset,
    Rect clipRect,
    PaintingContextCallback painter, {
    Clip clipBehavior = Clip.hardEdge,
    ClipRectLayer? oldLayer,
  }) {
    super.pushClipRect(
      false,
      offset,
      clipRect,
      painter,
      clipBehavior: clipBehavior,
    );
    return clipBehavior == Clip.none
        ? null
        : ClipRectLayer(
            clipRect: clipRect.shift(offset),
            clipBehavior: clipBehavior,
          );
  }

  @override
  ClipRRectLayer? pushClipRRect(
    bool needsCompositing,
    Offset offset,
    Rect bounds,
    RRect clipRRect,
    PaintingContextCallback painter, {
    Clip clipBehavior = Clip.antiAlias,
    ClipRRectLayer? oldLayer,
  }) {
    super.pushClipRRect(
      false,
      offset,
      bounds,
      clipRRect,
      painter,
      clipBehavior: clipBehavior,
    );
    return clipBehavior == Clip.none
        ? null
        : ClipRRectLayer(
            clipRRect: clipRRect.shift(offset),
            clipBehavior: clipBehavior,
          );
  }

  @override
  ClipPathLayer? pushClipPath(
    bool needsCompositing,
    Offset offset,
    Rect bounds,
    Path clipPath,
    PaintingContextCallback painter, {
    Clip clipBehavior = Clip.antiAlias,
    ClipPathLayer? oldLayer,
  }) {
    super.pushClipPath(
      false,
      offset,
      bounds,
      clipPath,
      painter,
      clipBehavior: clipBehavior,
    );
    return clipBehavior == Clip.none
        ? null
        : ClipPathLayer(
            clipPath: clipPath.shift(offset),
            clipBehavior: clipBehavior,
          );
  }

  @override
  TransformLayer? pushTransform(
    bool needsCompositing,
    Offset offset,
    Matrix4 transform,
    PaintingContextCallback painter, {
    TransformLayer? oldLayer,
  }) {
    super.pushTransform(false, offset, transform, painter);
    return TransformLayer(transform: transform);
  }

  @override
  OpacityLayer pushOpacity(
    Offset offset,
    int alpha,
    PaintingContextCallback painter, {
    OpacityLayer? oldLayer,
  }) {
    _hasher.addInt(37);
    _hasher.addInt(alpha);
    canvas.saveLayer(null, Paint()..color = Color.fromARGB(alpha, 0, 0, 0));
    painter(this, offset);
    canvas.restore();
    return OpacityLayer(alpha: alpha);
  }
}

/// How [GlassBackdropScope] renders its glass panes.
enum GlassRenderMode {
  /// [capture] everywhere except CanvasKit web builds (dart2js —
  /// `kIsWeb && !kIsWasm`), which get [backdropFilter]: there `toImageSync`
  /// is a synchronous GPU readback, making the capture pipeline slow.
  auto,

  /// Full capture pipeline: real refraction, dispersion, and
  /// backdrop-derived glare sampled from a retained capture of the scope.
  capture,

  /// BackdropFilter fallback: clipped backdrop blur + lens magnification +
  /// a backdrop-independent lighting shader. No capture or readbacks.
  /// Not reproduced: chromatic dispersion, `blurEdge: false`, and the
  /// backdrop-derived glare color.
  backdropFilter,
}

/// Wrap the app (or any subtree) once; every [LiquidGlassContainer] below it
/// samples this subtree's pixels as its backdrop.
///
/// [settings] become the inherited defaults for every descendant container;
/// a container's own [LiquidGlassContainer.settings] override them
/// field-wise (see [LiquidGlassSettings]).
///
/// The scope re-records the backdrop whenever the subtree repaints, but only
/// re-rasterizes (and bumps [RenderGlassScope.generation]) when the recorded
/// content actually changed — glass moving over a static backdrop reuses the
/// previous capture. Descendant repaint boundaries (viewports, list items,
/// [RepaintBoundary]s) repaint without marking the scope dirty; the scope
/// watches their retained layers after each frame and recaptures when one
/// changed, so the refraction follows scrolling and boundary-isolated
/// animations with at most one frame of latency.
///
/// Scopes must not be nested (asserts in debug): panes sample the nearest
/// scope, and an outer scope cannot capture through an inner one. Use a
/// single scope around the shared backdrop.
class GlassBackdropScope extends StatelessWidget {
  const GlassBackdropScope({
    super.key,
    this.settings,
    this.renderMode = GlassRenderMode.auto,
    required this.child,
  });

  /// Inherited settings for descendant containers; null fields fall back to
  /// [LiquidGlassSettings.defaults].
  final LiquidGlassSettings? settings;

  /// Rendering strategy; [GlassRenderMode.auto] picks per platform.
  final GlassRenderMode renderMode;

  final Widget child;

  static GlassRenderMode _resolveMode(GlassRenderMode mode) =>
      mode == GlassRenderMode.auto
      ? (kIsWeb && !kIsWasm
            ? GlassRenderMode.backdropFilter
            : GlassRenderMode.capture)
      : mode;

  /// The fully resolved settings containers inherit at [context]
  /// ([LiquidGlassSettings.defaults] when no scope is above).
  static LiquidGlassSettings settingsOf(BuildContext context) =>
      LiquidGlassSettings.defaults.merge(
        context
            .dependOnInheritedWidgetOfExactType<_GlassScopeMarker>()
            ?.settings,
      );

  /// The resolved render mode at [context] (never [GlassRenderMode.auto]);
  /// the platform default when no scope is above. Lets apps adapt to the
  /// fallback's missing effects (see [GlassRenderMode.backdropFilter]).
  static GlassRenderMode renderModeOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_GlassScopeMarker>()
          ?.renderMode ??
      _resolveMode(GlassRenderMode.auto);

  @override
  Widget build(BuildContext context) {
    final resolved = _resolveMode(renderMode);
    return _GlassScopeMarker(
      settings: settings,
      renderMode: resolved,
      child: _RawGlassScope(
        useFallback: resolved == GlassRenderMode.backdropFilter,
        child: child,
      ),
    );
  }
}

class _GlassScopeMarker extends InheritedWidget {
  const _GlassScopeMarker({
    required this.settings,
    required this.renderMode,
    required super.child,
  });

  final LiquidGlassSettings? settings;
  final GlassRenderMode renderMode; // resolved, never auto

  @override
  bool updateShouldNotify(_GlassScopeMarker oldWidget) =>
      settings != oldWidget.settings || renderMode != oldWidget.renderMode;
}

class _RawGlassScope extends SingleChildRenderObjectWidget {
  const _RawGlassScope({required this.useFallback, required super.child});

  final bool useFallback;

  // MediaQuery when available: unlike View.of, it notifies dependents when
  // the DPR changes (e.g. the window moves to a different-density monitor).
  static double _dprOf(BuildContext context) =>
      MediaQuery.maybeDevicePixelRatioOf(context) ??
      View.of(context).devicePixelRatio;

  @override
  RenderGlassScope createRenderObject(BuildContext context) =>
      RenderGlassScope(_dprOf(context), useFallback);

  @override
  void updateRenderObject(BuildContext context, RenderGlassScope renderObject) {
    renderObject
      .._setDevicePixelRatio(_dprOf(context))
      .._setFallbackActive(useFallback);
  }
}

/// Render object behind [GlassBackdropScope]: records the backdrop, detects
/// content changes, rasterizes the shared textures, and coordinates
/// glass-through-glass compositing. Exposed for tests and introspection
/// (see [generation], [isChurning], [fallbackActive], [hasBackdrop]); apps
/// normally interact with [GlassBackdropScope] only.
class RenderGlassScope extends RenderProxyBox {
  RenderGlassScope(this._devicePixelRatio, this._fallbackActive);

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    assert(() {
      for (RenderObject? node = parent; node != null; node = node.parent) {
        if (node is RenderGlassScope) {
          throw FlutterError(
            'GlassBackdropScope cannot be nested inside another '
            'GlassBackdropScope.\n'
            'Glass panes sample the nearest scope, and an outer scope cannot '
            'capture through an inner one. Use a single scope around the '
            'shared backdrop.',
          );
        }
      }
      return true;
    }());
  }

  double _devicePixelRatio;
  double get devicePixelRatio => _devicePixelRatio;
  void _setDevicePixelRatio(double value) {
    if (value == _devicePixelRatio) return;
    _devicePixelRatio = value;
    markNeedsPaint();
  }

  bool _fallbackActive;

  /// Whether containers paint via the BackdropFilter fallback.
  bool get fallbackActive => _fallbackActive;

  void _setFallbackActive(bool active) {
    if (active == _fallbackActive) return;
    _fallbackActive = active;
    if (active) {
      // capture machinery is dead weight while the fallback runs
      _clearEntries();
      _dropTextures();
      _captureLayer?.dispose();
      _captureLayer = null;
      _hashValid = false;
      _boundaries.clear();
      _boundarySigs.clear();
    }
    // containers switch between direct draws and pushed layers
    for (final c in _containers) {
      c.markNeedsCompositingBitsUpdate();
      c.markNeedsPaint();
    }
    markNeedsPaint();
  }

  /// Attached descendants, for compositing/paint invalidation on flag flips.
  final Set<RenderLiquidGlassContainer> _containers = {};

  /// True while the backdrop capture paint is running; containers skip
  /// painting so the capture holds only what's behind the glass (mirrors the
  /// reference's separate bg pass — no self-feedback, no frame lag).
  bool _capturing = false;

  /// Retained recording of the backdrop; containers rasterize only their own
  /// crop region from it via [captureRegion].
  OffsetLayer? _captureLayer;

  /// Bumped when the backdrop content actually changes; the shared texture
  /// cache below is keyed on it.
  int _generation = 0;
  int get generation => _generation;

  int _hashA = 0;
  int _hashB = 0;
  bool _hashValid = false;

  bool get hasBackdrop => _captureLayer != null;

  // Full-scope backdrop textures, shared by every container: position
  // independent (glass movement never invalidates them) and one set of GPU
  // readbacks per backdrop change instead of one per container. Only used
  // while the backdrop is static — when it churns every frame, full-scope
  // readbacks move far more data than the glass needs, so containers switch
  // to per-container crops (see [isChurning]).
  ui.Image? _sharpTex;
  final Map<int, ui.Image> _blurTexs = {};
  int _texGen = -1;
  double _texDpr = 0;

  int _stableStreak = 0;
  bool _churning = false;

  // Paint-order registry of glass containers, rebuilt every capture pass.
  // Drives glass-through-glass compositing: a container overlapped from below
  // composites the lower panes' recorded output into its backdrop textures.
  final List<_GlassEntry> _entries = [];
  final Map<RenderLiquidGlassContainer, int> _entryIndex = {};

  /// Last frame's glass states; a change schedules the stale-pane check.
  List<int> _prevGlassStates = const [];

  /// Sequence source for [_GlassEntry.childSeq] (unhashable child content).
  int _frameSeq = 0;

  // Descendant repaint boundaries are inlined into the capture, so their
  // independent repaints never mark the scope dirty (a scrolling viewport,
  // a list item's animation, a FadeTransition). The capture walk collects
  // them here; after every frame [_checkBoundaries] compares a signature of
  // each boundary's retained layer subtree and marks the scope dirty on any
  // change, so the capture follows with one frame of latency.
  final Set<RenderObject> _boundaries = {};
  final Map<RenderObject, int> _boundarySigs = {};
  bool _watcherArmed = false;

  /// Set when the capture inlined a boundary that had not composited yet (its
  /// layer was null, so a composited effect like opacity couldn't be applied);
  /// the boundary composites later in the same frame, so one post-frame
  /// recapture converges.
  bool _sawUncomposited = false;

  void _armBoundaryWatcher() {
    if (_watcherArmed || _boundaries.isEmpty) return;
    _watcherArmed = true;
    SchedulerBinding.instance.addPostFrameCallback(_checkBoundaries);
  }

  void _checkBoundaries(Duration _) {
    _watcherArmed = false;
    if (!attached || _fallbackActive) {
      _boundarySigs.clear();
      return;
    }
    var changed = false;
    final prev = Map<RenderObject, int>.of(_boundarySigs);
    _boundarySigs.clear();
    for (final b in _boundaries) {
      if (!b.attached) continue; // its removal repainted a tracked ancestor
      // ignore: invalid_use_of_protected_member
      final sig = _layerSig(b.layer);
      _boundarySigs[b] = sig;
      final p = prev[b];
      if (p != null && p != sig) changed = true;
    }
    // A no-op recapture (unchanged hash) costs a re-record, never a raster,
    // so a false positive is cheap; a miss would leave the glass stale.
    if (changed) markNeedsPaint();
    _armBoundaryWatcher();
  }

  /// Identity-fold of a retained layer subtree: repaints replace picture
  /// layers, composited-layer updates mutate [OpacityLayer.alpha] /
  /// [ImageFilterLayer.imageFilter] in place, and both must invalidate.
  /// (Texture and platform-view frames change nothing Dart-visible — those
  /// stay outside the refraction, as documented.)
  static int _layerSig(Layer? root) {
    if (root == null) return 0;
    final h = _FrameHasher();
    void fold(Layer l) {
      h.addInt(identityHashCode(l));
      if (l is PictureLayer) {
        h.addInt(identityHashCode(l.picture));
        return;
      }
      if (l is OffsetLayer) {
        h.addDouble(l.offset.dx);
        h.addDouble(l.offset.dy);
        if (l is OpacityLayer) {
          h.addInt(l.alpha ?? -1);
        } else if (l is ImageFilterLayer) {
          h.addInt(identityHashCode(l.imageFilter));
        }
      }
      if (l is ContainerLayer) {
        for (Layer? c = l.firstChild; c != null; c = c.nextSibling) {
          fold(c);
        }
      }
    }

    fold(root);
    // both 30-bit lanes, exact within web-safe integer range
    return h.a * 0x40000000 + h.b;
  }

  /// Records each sampled pane's child into its entry (scope-logical
  /// coordinates), so upper panes composite the child along with the glass.
  /// Children are inlined through the same hashing context as the backdrop:
  /// the hash folds into the glass state so child content changes invalidate
  /// upper panes' composited textures. Content that can't be recorded into
  /// pictures (platform views, textures) is omitted from the refraction.
  void _recordChildren() {
    for (var i = 0; i < _entries.length; i++) {
      final e = _entries[i];
      final childBox = e.container.child;
      if (childBox == null) continue;
      var sampled = false;
      for (var j = i + 1; j < _entries.length; j++) {
        if (_entries[j].sampleBounds.overlaps(e.paintBounds)) {
          sampled = true;
          break;
        }
      }
      if (!sampled) continue;
      final hasher = _FrameHasher();
      final root = ContainerLayer();
      final ctx = _GlassCaptureContext(
        root,
        Offset.zero & size,
        hasher,
        this,
        registerGlass: false,
      );
      final paneOrigin = e.glassPx.topLeft / _devicePixelRatio;
      final childOffset = (childBox.parentData! as BoxParentData).offset;
      final clip = e.container._clipBehavior;
      if (clip == Clip.none) {
        ctx.paintChild(childBox, paneOrigin + childOffset);
      } else {
        // same clip as the live child paint (_paintChild)
        ctx.pushClipPath(
          false,
          paneOrigin,
          Offset.zero & e.container.size,
          e.container._glassPathFor(e.container.size),
          (c, o) => c.paintChild(childBox, o + childOffset),
          clipBehavior: clip,
        );
      }
      // ignore: invalid_use_of_protected_member
      ctx.stopRecordingIfNeeded();
      e.childLayer = root;
      e.childPictures = _collectPictures(root);
      e.childHashA = hasher.a;
      e.childHashB = hasher.b;
      // FragmentShader paints can mutate without a hash change: force the
      // state to differ every frame so the composite never goes stale.
      e.childSeq = hasher.poisoned ? ++_frameSeq : 0;
    }
  }

  /// The push* overrides force everything inline, so the recorded layer tree
  /// is (possibly nested) PictureLayers plus unrecordable layers, which are
  /// skipped.
  static List<ui.Picture> _collectPictures(ContainerLayer root) {
    final out = <ui.Picture>[];
    void visit(Layer? l) {
      for (; l != null; l = l.nextSibling) {
        if (l is PictureLayer) {
          final p = l.picture;
          if (p != null) out.add(p);
        } else if (l is ContainerLayer) {
          visit(l.firstChild);
        }
      }
    }

    visit(root.firstChild);
    return out;
  }

  void _registerGlass(RenderLiquidGlassContainer c, Offset offsetLogical) {
    final dpr = _devicePixelRatio;
    final glassPx = (offsetLogical * dpr) & c.size * dpr;
    // Overlap-test bounds are deliberately tight (glass body + AA margin, and
    // for sampling the blur smear): the theoretical refraction reach covers a
    // ~1px rim band at extreme angles — not worth per-frame compositing for
    // panes that merely sit near each other.
    final paintBounds = glassPx.inflate(2 * dpr);
    final sampleBounds = glassPx.inflate(
      8 * dpr + 2.0 * c.settings.blurRadius! * dpr,
    );
    _entryIndex[c] = _entries.length;
    _entries.add(
      _GlassEntry(c, glassPx, paintBounds, sampleBounds, c._stateHash(glassPx)),
    );
  }

  void _clearEntries() {
    for (final e in _entries) {
      e.picture?.dispose();
      e.childLayer?.dispose(); // also disposes the pictures it owns
    }
    _entries.clear();
    _entryIndex.clear();
  }

  /// Lower panes whose output lands inside [c]'s sampled area.
  List<_GlassEntry> _lowerIntersecting(RenderLiquidGlassContainer c) {
    final idx = _entryIndex[c];
    if (idx == null || idx == 0) return const [];
    final sampled = _entries[idx].sampleBounds;
    return [
      for (var i = 0; i < idx; i++)
        if (_entries[i].paintBounds.overlaps(sampled)) _entries[i],
    ];
  }

  /// Whether any later pane samples this one's output (so it must record it).
  bool _needsPicture(RenderLiquidGlassContainer c) {
    final idx = _entryIndex[c];
    if (idx == null) return false;
    final mine = _entries[idx].paintBounds;
    for (var i = idx + 1; i < _entries.length; i++) {
      if (_entries[i].sampleBounds.overlaps(mine)) return true;
    }
    return false;
  }

  _GlassEntry? _entryOf(RenderLiquidGlassContainer c) {
    final idx = _entryIndex[c];
    return idx == null ? null : _entries[idx];
  }

  /// True while the backdrop content is changing on consecutive frames
  /// (animated backdrop). Containers then rasterize their own crops instead
  /// of the shared full-scope textures. Exits after a stretch of stable
  /// frames so an every-other-frame animation can't flip-flop the strategy.
  bool get isChurning => _churning;

  void _dropTextures() {
    _sharpTex?.dispose();
    _sharpTex = null;
    for (final t in _blurTexs.values) {
      t.dispose();
    }
    _blurTexs.clear();
  }

  /// Rasterizes the given region (scope device px) of the backdrop recording.
  ui.Image _captureRegion(Rect devicePxRect) => _captureLayer!.toImageSync(
    Rect.fromLTRB(
      devicePxRect.left / _devicePixelRatio,
      devicePxRect.top / _devicePixelRatio,
      devicePxRect.right / _devicePixelRatio,
      devicePxRect.bottom / _devicePixelRatio,
    ),
    pixelRatio: _devicePixelRatio,
  );

  /// Full-scope raster of the backdrop recording (device px).
  ui.Image _sharpTexture() {
    if (_texGen != _generation || _texDpr != _devicePixelRatio) {
      _dropTextures();
      _sharpTex = _captureLayer!.toImageSync(
        Offset.zero & size,
        pixelRatio: _devicePixelRatio,
      );
      _texGen = _generation;
      _texDpr = _devicePixelRatio;
    }
    return _sharpTex!;
  }

  /// Blurred counterpart per distinct blur radius, via Skia's gaussian
  /// (sigma = radius/3 like the reference), rendered downscaled — blur is
  /// low-frequency, and fewer pixels mean a cheaper readback on CanvasKit.
  /// At radius <= 2 the blur is sub-pixel: the sharp texture is aliased
  /// instead of building (and reading back) a near-identical copy.
  ///
  /// LRU-capped: an animated blur radius over a static backdrop would
  /// otherwise accumulate one texture per distinct radius until the next
  /// backdrop change. The cap keeps every radius in concurrent use (bounded
  /// by the container count); evicted images stay alive while recorded
  /// pictures still reference them (dart:ui images are refcounted).
  ui.Image _blurredTexture(int radius) {
    final sharp = _sharpTexture(); // refreshes cache key, drops stale blurs
    if (radius <= 2) return sharp;
    final cached = _blurTexs.remove(radius);
    if (cached != null) {
      _blurTexs[radius] = cached; // reinsert: most recently used last
      return cached;
    }
    final img = _blur(sharp, radius);
    _blurTexs[radius] = img;
    final cap = math.max(8, _containers.length);
    while (_blurTexs.length > cap) {
      _blurTexs.remove(_blurTexs.keys.first)!.dispose();
    }
    return img;
  }

  /// Number of cached blurred full-scope textures (see [_blurredTexture]).
  @visibleForTesting
  int get debugBlurTextureCount => _blurTexs.length;

  static ui.Image _blur(ui.Image src, int radius) {
    final ds = radius >= 12 ? 4.0 : (radius >= 4 ? 2.0 : 1.0);
    final sigma = math.max(radius / 3.0 / ds, 0.1);
    final w = (src.width / ds).ceil();
    final h = (src.height / ds).ceil();
    final rec = ui.PictureRecorder();
    Canvas(rec).drawImageRect(
      src,
      Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()
        ..filterQuality = FilterQuality.low
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: sigma,
          sigmaY: sigma,
          tileMode: TileMode.clamp,
        ),
    );
    final pic = rec.endRecording();
    final img = pic.toImageSync(w, h);
    pic.dispose();
    return img;
  }

  @override
  bool get isRepaintBoundary => true;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size.isEmpty || child == null) return;

    if (_fallbackActive) {
      // no capture pass: containers sample the scene via BackdropFilter
      super.paint(context, offset);
      return;
    }

    _capturing = true;
    _clearEntries();
    _boundaries.clear();
    _sawUncomposited = false;
    final OffsetLayer captureLayer = OffsetLayer();
    // Fold the scope geometry: identical draw commands at a new size or DPR
    // must not reuse the old full-scope texture.
    final hasher = _FrameHasher()
      ..addDouble(size.width)
      ..addDouble(size.height)
      ..addDouble(_devicePixelRatio);
    final captureContext = _GlassCaptureContext(
      captureLayer,
      Offset.zero & size,
      hasher,
      this,
    );
    var captured = false;
    try {
      super.paint(captureContext, Offset.zero);
      // Same pattern as the framework's SnapshotWidget.
      // ignore: invalid_use_of_protected_member
      captureContext.stopRecordingIfNeeded();
      captured = true;
    } finally {
      // one throwing backdrop widget must not disable glass for the scope's
      // lifetime, and the partial recording must not leak
      _capturing = false;
      if (!captured) captureLayer.dispose();
    }
    _recordChildren();
    _armBoundaryWatcher();
    if (_sawUncomposited) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (attached && !_fallbackActive) markNeedsPaint();
      });
    }

    final bool unchanged =
        _captureLayer != null &&
        _hashValid &&
        !hasher.poisoned &&
        hasher.sameAs(_hashA, _hashB);
    if (unchanged) {
      captureLayer.dispose();
      _stableStreak++;
      if (_churning && _stableStreak >= 30) _churning = false;
    } else {
      _captureLayer?.dispose();
      _captureLayer = captureLayer;
      _generation++;
      _stableStreak = 0;
      if (!_churning) {
        _churning = true;
        _dropTextures(); // full-scope textures are dead weight while churning
      }
    }
    _hashA = hasher.a;
    _hashB = hasher.b;
    _hashValid = !hasher.poisoned;

    // any glass geometry/param/child-content change schedules the stale-pane
    // check (panes key their composite crops on these states themselves)
    final states = [
      for (final e in _entries)
        Object.hash(e.stateHash, e.childHashA, e.childHashB, e.childSeq),
    ];
    final epochChanged = !listEquals(states, _prevGlassStates);
    if (epochChanged) _prevGlassStates = states;

    // Panes inside a clean repaint boundary do not repaint with the scope;
    // after a generation or epoch change, mark the ones whose last paint
    // predates it (checked post-frame, when this frame's paints are done).
    if ((!unchanged || epochChanged) && !_stalePaneCheckScheduled) {
      _stalePaneCheckScheduled = true;
      SchedulerBinding.instance.addPostFrameCallback(_markStalePanes);
    }

    super.paint(context, offset);
  }

  bool _stalePaneCheckScheduled = false;

  void _markStalePanes(Duration _) {
    _stalePaneCheckScheduled = false;
    if (!attached || _fallbackActive) return;
    for (final c in _containers) {
      if (!c.attached) continue;
      if (c._lastPaintedGen != _generation) {
        c.markNeedsPaint();
        continue;
      }
      final e = _entryOf(c);
      if (e == null) continue; // not registered this frame (culled)
      // only this pane's own geometry/params or its lower set can make its
      // painted output stale; unrelated panes must not cause repaints
      if (e.stateHash != c._lastPaintedOwnState ||
          _lowerStatesHash(_lowerIntersecting(c)) != c._lastPaintedLowerHash) {
        c.markNeedsPaint();
      }
    }
  }

  /// Combined state of the lower panes whose output a pane composites.
  static int _lowerStatesHash(List<_GlassEntry> lower) => lower.isEmpty
      ? 0
      : Object.hashAll([
          for (final e in lower)
            Object.hash(e.stateHash, e.childHashA, e.childHashB, e.childSeq),
        ]);

  @override
  void dispose() {
    _clearEntries();
    _dropTextures();
    _captureLayer?.dispose();
    _captureLayer = null;
    _boundaries.clear();
    _boundarySigs.clear();
    super.dispose();
  }
}

/// One glass container's slot in the scope's paint-order registry.
class _GlassEntry {
  _GlassEntry(
    this.container,
    this.glassPx,
    this.paintBounds,
    this.sampleBounds,
    this.stateHash,
  );

  final RenderLiquidGlassContainer container;
  final Rect glassPx;
  final Rect paintBounds;
  final Rect sampleBounds;
  final int stateHash;

  /// This frame's recorded glass output (scope-logical coords), set by the
  /// container during its paint when a later pane needs to sample it.
  ui.Picture? picture;

  /// The pane child's recorded output (scope-logical coords), captured by
  /// [RenderGlassScope._recordChildren] when a later pane samples this one.
  /// [childLayer] owns the pictures in [childPictures]; disposing it frees
  /// them.
  ContainerLayer? childLayer;
  List<ui.Picture> childPictures = const [];
  int childHashA = 0, childHashB = 0;

  /// Non-zero (a fresh sequence number) when the child recording contains
  /// unhashable content, so its state never compares equal across frames.
  int childSeq = 0;
}

/// A glass pane with the liquid-glass effect, ported from
/// https://github.com/iyinchao/liquid-glass-studio (STEP 9 composite).
///
/// Must be a descendant of a [GlassBackdropScope]. Visuals come from
/// [settings], resolved field-wise over the scope's settings and
/// [LiquidGlassSettings.defaults]. Pass only the fields to override.
///
/// Sizing follows [Container]: explicit [width]/[height] win; otherwise the
/// pane wraps [child] (plus [padding]) or, childless, expands to the
/// incoming constraints. The child is laid out loosely inside the padded
/// pane at [alignment] and painted on top of the glass: its own pane never
/// refracts or blurs it, but a pane stacked on top samples it like any other
/// content below (child content drawn via platform views or textures is the
/// exception — it can't be recorded, so it is omitted from the upper pane's
/// refraction). The pane itself hit-tests its exact shape, so corners
/// outside the superellipse pass touches through.
class LiquidGlassContainer extends SingleChildRenderObjectWidget {
  const LiquidGlassContainer({
    super.key,
    this.width,
    this.height,
    this.padding = EdgeInsets.zero,
    this.alignment = Alignment.center,
    this.clipBehavior = Clip.none,
    this.settings,
    super.child,
  });

  /// Optionally call before the first build to avoid a blank first frame
  /// (before `runApp`, call `WidgetsFlutterBinding.ensureInitialized()`
  /// first). Never completes with an error: a shader load failure is
  /// reported to [FlutterError] and containers paint their children without
  /// glass.
  static Future<void> precache() => _GlassShaders.ensureLoaded();

  /// Fixed pane size (logical px, constrained by the parent). Null: size to
  /// [child] + [padding], or expand when childless.
  final double? width;
  final double? height;

  /// Space between the pane edge and [child].
  final EdgeInsetsGeometry padding;

  /// [child]'s placement within the padded pane.
  final AlignmentGeometry alignment;

  /// Clips [child] to the glass shape when not [Clip.none].
  final Clip clipBehavior;

  /// Per-pane overrides of the scope's settings (field-wise, null inherits).
  final LiquidGlassSettings? settings;

  LiquidGlassSettings _resolveSettings(BuildContext context) {
    final marker = context
        .dependOnInheritedWidgetOfExactType<_GlassScopeMarker>();
    assert(() {
      if (marker == null) {
        throw FlutterError.fromParts([
          ErrorSummary(
            'LiquidGlassContainer used outside a GlassBackdropScope.',
          ),
          ErrorDescription(
            'Glass panes refract the pixels of the subtree wrapped by a '
            'GlassBackdropScope; without one there is no backdrop to sample.',
          ),
          ErrorHint(
            'Wrap the subtree containing both the backdrop content and the '
            'glass panes in a GlassBackdropScope.',
          ),
        ]);
      }
      return true;
    }());
    return LiquidGlassSettings.defaults.merge(marker?.settings).merge(settings);
  }

  @override
  RenderLiquidGlassContainer createRenderObject(BuildContext context) {
    final direction = Directionality.maybeOf(context) ?? TextDirection.ltr;
    return RenderLiquidGlassContainer(
      settings: _resolveSettings(context),
      width: width,
      height: height,
      padding: padding.resolve(direction),
      alignment: alignment.resolve(direction),
      clipBehavior: clipBehavior,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    RenderLiquidGlassContainer renderObject,
  ) {
    final direction = Directionality.maybeOf(context) ?? TextDirection.ltr;
    renderObject
      ..settings = _resolveSettings(context)
      ..width = width
      ..height = height
      ..padding = padding.resolve(direction)
      ..alignment = alignment.resolve(direction)
      ..clipBehavior = clipBehavior;
  }
}

/// Render object behind [LiquidGlassContainer]: lays out like [Container]
/// (explicit size ← wrap child + padding ← expand), hit-tests the glass
/// outline, and paints the pane via the capture pipeline or the
/// BackdropFilter fallback. Exposed for tests and introspection; apps
/// normally use [LiquidGlassContainer].
class RenderLiquidGlassContainer extends RenderBox
    with RenderObjectWithChildMixin<RenderBox> {
  RenderLiquidGlassContainer({
    required this._settings,
    required this._width,
    required this._height,
    required this._padding,
    required this._alignment,
    required this._clipBehavior,
  });

  /// Fully resolved (every field non-null, see [LiquidGlassSettings]).
  LiquidGlassSettings _settings;
  LiquidGlassSettings get settings => _settings;
  set settings(LiquidGlassSettings value) {
    if (value == _settings) return;
    _settings = value;
    markNeedsPaint();
  }

  double? _width;
  set width(double? value) {
    if (value == _width) return;
    _width = value;
    markNeedsLayout();
  }

  double? _height;
  set height(double? value) {
    if (value == _height) return;
    _height = value;
    markNeedsLayout();
  }

  EdgeInsets _padding;
  set padding(EdgeInsets value) {
    if (value == _padding) return;
    _padding = value;
    markNeedsLayout();
  }

  Alignment _alignment;
  set alignment(Alignment value) {
    if (value == _alignment) return;
    _alignment = value;
    markNeedsLayout();
  }

  Clip _clipBehavior;
  set clipBehavior(Clip value) {
    if (value == _clipBehavior) return;
    _clipBehavior = value;
    if (value == Clip.none) _childClip.layer = null;
    markNeedsPaint();
  }

  @override
  void setupParentData(RenderObject child) {
    if (child.parentData is! BoxParentData) child.parentData = BoxParentData();
  }

  /// Churn-mode crops are snapped out to this grid (device px) so small glass
  /// movements keep hitting the cache between backdrop changes.
  static const double _cropGrid = 128;

  ui.FragmentShader? _shader;
  final Paint _glassPaint = Paint();

  // Churn-mode texture cache (see RenderGlassScope.isChurning): this
  // container's crop of the backdrop, sharp + blurred.
  ui.Image? _sharp;
  ui.Image? _blurred;
  Rect? _texCrop;
  int _texGen = -1;
  int _texRadius = -1;
  double _texDpr = 0;
  int _texKind = -1; // 0 = backdrop only, 1 = composited with lower glass
  int _texLowerHash = 0;

  /// Stamps of the scope state this pane last painted with; the scope marks
  /// panes whose stamps lag (they sit inside a clean repaint boundary and do
  /// not repaint with the scope). Own state and lower-set state are stamped
  /// separately, so an unrelated pane's movement does not mark this one.
  int _lastPaintedGen = -1;
  int _lastPaintedOwnState = 0;
  int _lastPaintedLowerHash = 0;

  /// Crop texture rebuilds, for tests (debug builds only).
  @visibleForTesting
  static int debugCropTextureBuilds = 0;

  // Second shader instance for the recorded-output picture: its uniforms
  // differ from the scene draw's within the same frame.
  ui.FragmentShader? _compShader;

  Path? _glassPath;
  double _pathW = -1, _pathH = -1, _pathR = -1, _pathN = -1;

  RenderGlassScope? _scope;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    RenderObject? node = parent;
    while (node != null && node is! RenderGlassScope) {
      node = node.parent;
    }
    _scope = node as RenderGlassScope?;
    _scope?._containers.add(this);
  }

  @override
  void detach() {
    _scope?._containers.remove(this);
    _scope = null;
    super.detach();
  }

  // The fallback pushes ClipPath/BackdropFilter layers, so ancestors must use
  // composited clips/transforms around this box.
  @override
  bool get alwaysNeedsCompositing => _scope?._fallbackActive ?? false;

  void _dropCropTextures() {
    _sharp?.dispose();
    // _blurred may alias _sharp at small radii
    if (!identical(_blurred, _sharp)) _blurred?.dispose();
    _sharp = null;
    _blurred = null;
    _texCrop = null;
    _texGen = -1;
  }

  // Container semantics: explicit dims win; else wrap child + padding; else
  // expand to bounded constraints. Layout is pure, so dry layout, dry
  // baseline, and performLayout share these helpers.

  BoxConstraints _tightenFor(BoxConstraints constraints) =>
      _width != null || _height != null
      ? constraints.tighten(width: _width, height: _height)
      : constraints;

  /// Pane size for already-[_tightenFor]ed constraints; [childSize] null when
  /// childless.
  Size _paneSizeFor(BoxConstraints c, Size? childSize) => c.constrain(
    childSize == null
        ? Size(
            _width ?? (c.hasBoundedWidth ? c.maxWidth : 0),
            _height ?? (c.hasBoundedHeight ? c.maxHeight : 0),
          )
        : Size(
            _width ?? childSize.width + _padding.horizontal,
            _height ?? childSize.height + _padding.vertical,
          ),
  );

  /// [child]'s top-left within a pane of [paneSize].
  Offset _childOffsetFor(Size paneSize, Size childSize) {
    final content = Rect.fromLTRB(
      _padding.left,
      _padding.top,
      paneSize.width - _padding.right,
      paneSize.height - _padding.bottom,
    );
    return _alignment.inscribe(childSize, content).topLeft;
  }

  @override
  void performLayout() {
    final c = _tightenFor(constraints);
    final ch = child;
    if (ch == null) {
      size = _paneSizeFor(c, null);
      return;
    }
    ch.layout(c.deflate(_padding).loosen(), parentUsesSize: true);
    size = _paneSizeFor(c, ch.size);
    (ch.parentData! as BoxParentData).offset = _childOffsetFor(size, ch.size);
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final c = _tightenFor(constraints);
    return _paneSizeFor(c, child?.getDryLayout(c.deflate(_padding).loosen()));
  }

  @override
  double? computeDryBaseline(BoxConstraints constraints, TextBaseline baseline) {
    final ch = child;
    if (ch == null) return null;
    final c = _tightenFor(constraints);
    final cc = c.deflate(_padding).loosen();
    final d = ch.getDryBaseline(cc, baseline);
    if (d == null) return null;
    final childSize = ch.getDryLayout(cc);
    return d + _childOffsetFor(_paneSizeFor(c, childSize), childSize).dy;
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) {
    final ch = child;
    if (ch == null) return null;
    final d = ch.getDistanceToActualBaseline(baseline);
    return d == null ? null : d + (ch.parentData! as BoxParentData).offset.dy;
  }

  double _intrinsicWidth(double height, double Function(RenderBox, double) f) {
    if (_width != null) return _width!;
    final ch = child;
    if (ch == null) return 0;
    final h = math.max(0.0, (_height ?? height) - _padding.vertical);
    return f(ch, h) + _padding.horizontal;
  }

  double _intrinsicHeight(double width, double Function(RenderBox, double) f) {
    if (_height != null) return _height!;
    final ch = child;
    if (ch == null) return 0;
    final w = math.max(0.0, (_width ?? width) - _padding.horizontal);
    return f(ch, w) + _padding.vertical;
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      _intrinsicWidth(height, (c, h) => c.getMinIntrinsicWidth(h));

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _intrinsicWidth(height, (c, h) => c.getMaxIntrinsicWidth(h));

  @override
  double computeMinIntrinsicHeight(double width) =>
      _intrinsicHeight(width, (c, w) => c.getMinIntrinsicHeight(w));

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _intrinsicHeight(width, (c, w) => c.getMaxIntrinsicHeight(w));

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final c = child;
    if (c == null) return false;
    return result.addWithPaintOffset(
      offset: (c.parentData! as BoxParentData).offset,
      position: position,
      hitTest: (r, p) => c.hitTest(r, position: p),
    );
  }

  // The pane is a surface: it absorbs hits within its exact outline (and
  // only there — square corners outside the superellipse pass through).
  @override
  bool hitTestSelf(Offset position) => _glassPathFor(size).contains(position);

  final LayerHandle<ClipPathLayer> _childClip = LayerHandle<ClipPathLayer>();

  void _paintChild(PaintingContext context, Offset offset) {
    final c = child;
    if (c == null) return;
    final childOffset = (c.parentData! as BoxParentData).offset;
    if (_clipBehavior == Clip.none) {
      context.paintChild(c, offset + childOffset);
    } else {
      _childClip.layer = context.pushClipPath(
        needsCompositing,
        offset,
        Offset.zero & size,
        _glassPathFor(size),
        (ctx, o) => ctx.paintChild(c, o + childOffset),
        clipBehavior: _clipBehavior,
        oldLayer: _childClip.layer,
      );
    }
  }

  /// Superellipse-cornered rounded rect matching the shader's SDF; used for
  /// the AA edge clip, hit testing, and the drop shadow.
  Path _glassPathFor(Size s) {
    final shape = _settings.shape!;
    final r = shape.resolveRadius(s);
    final n = shape.roundness;
    if (_glassPath != null &&
        _pathW == s.width &&
        _pathH == s.height &&
        _pathR == r &&
        _pathN == n) {
      return _glassPath!;
    }
    final path = _superellipsePath(s.width, s.height, r, n);
    _glassPath = path;
    _pathW = s.width;
    _pathH = s.height;
    _pathR = r;
    _pathN = n;
    return path;
  }

  static Path _superellipsePath(double w, double h, double r, double n) {
    final path = Path();
    if (r < 0.05) {
      path.addRect(Rect.fromLTWH(0, 0, w, h));
      return path;
    }
    final k = 2 / n;
    const seg = 24;
    // unit superellipse quarter, sampled once
    final cs = List<double>.generate(seg + 1, (i) {
      final t = i * (math.pi / 2) / seg;
      return math.pow(math.cos(t), k).toDouble();
    });
    final sn = List<double>.generate(seg + 1, (i) {
      final t = i * (math.pi / 2) / seg;
      return math.pow(math.sin(t), k).toDouble();
    });
    path.moveTo(0, r);
    for (var i = 0; i <= seg; i++) {
      path.lineTo(r - r * cs[i], r - r * sn[i]); // top-left
    }
    for (var i = 0; i <= seg; i++) {
      path.lineTo(w - r + r * sn[i], r - r * cs[i]); // top-right
    }
    for (var i = 0; i <= seg; i++) {
      path.lineTo(w - r + r * cs[i], h - r + r * sn[i]); // bottom-right
    }
    for (var i = 0; i <= seg; i++) {
      path.lineTo(r - r * sn[i], h - r + r * cs[i]); // bottom-left
    }
    path.close();
    return path;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!_GlassShaders.loaded) {
      if (_GlassShaders.failed) {
        _paintChild(context, offset); // shaders unavailable: content, no glass
        return;
      }
      _GlassShaders.ensureLoaded().then((_) {
        if (attached) markNeedsPaint();
      });
      return;
    }

    final scope = _scope;
    assert(
      scope != null,
      'LiquidGlassContainer must be inside a GlassBackdropScope',
    );
    if (scope == null) return;
    if (scope._fallbackActive) {
      _paintFallback(context, offset, scope);
      return;
    }
    if (_fbClip.layer != null) _releaseFbLayers(); // left from a flag flip
    if (scope._capturing || !scope.hasBackdrop) return;

    final dpr = scope.devicePixelRatio;
    final scopePx = Rect.fromLTWH(
      0,
      0,
      (scope.size.width * dpr).ceilToDouble(),
      (scope.size.height * dpr).ceilToDouble(),
    );

    // Container origin in scope device px (assumes translation-only transforms
    // between container and scope).
    final toScope = getTransformTo(scope);
    final originScope = MatrixUtils.transformPoint(toScope, Offset.zero) * dpr;
    final glassPx = originScope & size * dpr;
    final entry = scope._entryOf(this);
    final lower = scope._lowerIntersecting(this);
    final lowerHash = RenderGlassScope._lowerStatesHash(lower);
    // Stamps for the post-frame stale-pane check, taken from the registry so
    // the later comparison uses the same source.
    _lastPaintedGen = scope.generation;
    _lastPaintedOwnState = entry?.stateHash ?? 0;
    _lastPaintedLowerHash = lowerHash;
    if (!glassPx.overlaps(scopePx)) return;

    // Sampled area (glass + refraction/dispersion/blur reach); lower panes
    // whose output lands inside it must show through this one.
    final needed = glassPx
        .inflate(_reachFor(_settings, dpr).ceilToDouble())
        .intersect(scopePx);
    // texture cache and shader blur operate in integer device px
    final devBlur = (_settings.blurRadius! * dpr).round();

    final ui.Image sharp;
    final ui.Image blurred;
    final Rect texRect; // u_cropOrigin/u_cropSize
    if (lower.isNotEmpty || scope.isChurning) {
      // Crop textures: when overlapped from below, the crop composites the
      // lower panes' recorded output over the backdrop (so this pane refracts
      // them); on an animated backdrop a crop is also far less readback data
      // per frame than the full scope.
      _ensureCropTextures(scope, needed, scopePx, lower, lowerHash, devBlur);
      sharp = _sharp!;
      blurred = _blurred!;
      texRect = _texCrop!;
    } else {
      // Static backdrop, nothing underneath: shared full-scope textures,
      // position independent (sampling clamps at the scope edge, exactly
      // like the reference).
      _dropCropTextures();
      sharp = scope._sharpTexture();
      blurred = scope._blurredTexture(devBlur);
      texRect = scopePx;
    }

    _glassPathFor(size); // refreshes _pathR before the uniforms read it
    final shadowIntensity = _settings.shadowIntensity!;
    _setUniforms(
      _shader ??= _GlassShaders.main.fragmentShader(),
      scopePx,
      dpr,
      offset,
      originScope,
      texRect,
      sharp,
      blurred,
      shadowIntensity,
    );
    _paintGlass(context.canvas, offset, _shader!, shadowIntensity);

    // If a later pane samples this one, record the same output (in scope
    // coordinates) so it can be composited into that pane's backdrop.
    if (entry != null && scope._needsPicture(this)) {
      final originLogical = originScope / dpr;
      final ps = _compShader ??= _GlassShaders.main.fragmentShader();
      _setUniforms(
        ps,
        scopePx,
        dpr,
        originLogical,
        originScope,
        texRect,
        sharp,
        blurred,
        shadowIntensity,
      );
      final rec = ui.PictureRecorder();
      _paintGlass(Canvas(rec), originLogical, ps, shadowIntensity);
      entry.picture?.dispose();
      entry.picture = rec.endRecording();
    }

    _paintChild(context, offset);
  }

  /// Max sampling offset in device px: refraction (70.71 * cot(asin(1/n)) *
  /// dpr, per the shader's normal magnitude) times the dispersion scale, plus
  /// 2*blurRadius for the gaussian.
  static double _reachFor(LiquidGlassSettings cfg, double dpr) {
    final ior = cfg.indexOfRefraction!;
    final edgeFactorMax = ior <= 1 ? 0.0 : 1 / math.tan(math.asin(1 / ior));
    return 70.71 * edgeFactorMax * dpr * (1 + 0.02 * cfg.dispersion!) +
        2.0 * cfg.blurRadius! * dpr +
        2;
  }

  /// Everything that determines this pane's rendered output (given the same
  /// backdrop); folded into the scope's glass epoch.
  int _stateHash(Rect glassPx) => Object.hash(
    glassPx.left,
    glassPx.top,
    glassPx.right,
    glassPx.bottom,
    _settings,
  );

  /// Draws the drop shadow and the clipped glass rect at [drawOrigin] in the
  /// canvas's current space (scene: logical local px; recording: scope
  /// logical px).
  void _paintGlass(
    Canvas canvas,
    Offset drawOrigin,
    ui.FragmentShader shader,
    double shadowIntensity,
  ) {
    final glassPath = _glassPathFor(size);

    // Drop shadow: the reference's exp(-|sdf|/expand) falloff, approximated
    // by a gaussian mask blur of the shape (deviation: gaussian tail, and
    // multiplicative rather than subtractive darkening).
    if (shadowIntensity > 0) {
      _paintShadow(canvas, glassPath, drawOrigin, shadowIntensity);
    }

    // Glass composite: one direct draw, edge anti-aliased by the clip.
    canvas.save();
    canvas.clipPath(glassPath.shift(drawOrigin));
    canvas.drawRect(drawOrigin & size, _glassPaint..shader = shader);
    canvas.restore();
  }

  void _paintShadow(
    Canvas canvas,
    Path glassPath,
    Offset drawOrigin,
    double shadowIntensity,
  ) {
    canvas.drawPath(
      glassPath.shift(drawOrigin + _settings.shadowOffset!),
      Paint()
        ..color = Color.fromARGB(
          (255 * (0.6 * shadowIntensity).clamp(0.0, 1.0)).round(),
          0,
          0,
          0,
        )
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          math.max(_settings.shadowBlur!, 0.1),
        ),
    );
  }

  void _setUniforms(
    ui.FragmentShader s,
    Rect scopePx,
    double dpr,
    Offset drawOrigin,
    Offset originScope,
    Rect texRect,
    ui.Image sharp,
    ui.Image blurred,
    double shadowIntensity,
  ) {
    final cfg = _settings;
    var i = 0;
    s.setFloat(i++, scopePx.width); // u_scopeRes
    s.setFloat(i++, scopePx.height);
    s.setFloat(i++, dpr); // u_dpr
    s.setFloat(i++, drawOrigin.dx); // u_drawOrigin
    s.setFloat(i++, drawOrigin.dy);
    s.setFloat(i++, size.width); // u_size
    s.setFloat(i++, size.height);
    s.setFloat(i++, originScope.dx); // u_originScope
    s.setFloat(i++, originScope.dy);
    s.setFloat(i++, _pathR); // u_shapeRadius (computed by _glassPathFor)
    s.setFloat(i++, cfg.shape!.roundness); // u_shapeRoundness
    final tint = cfg.tint!;
    s.setFloat(i++, tint.r); // u_tint
    s.setFloat(i++, tint.g);
    s.setFloat(i++, tint.b);
    s.setFloat(i++, tint.a);
    s.setFloat(i++, cfg.thickness!);
    s.setFloat(i++, cfg.indexOfRefraction!);
    s.setFloat(i++, cfg.dispersion!);
    s.setFloat(i++, cfg.fresnelRange!);
    s.setFloat(i++, cfg.fresnelHardness!);
    s.setFloat(i++, cfg.fresnelIntensity!);
    s.setFloat(i++, cfg.glareRange!);
    s.setFloat(i++, cfg.glareHardness!);
    s.setFloat(i++, cfg.glareConvergence!);
    s.setFloat(i++, cfg.glareOppositeIntensity!);
    s.setFloat(i++, cfg.glareIntensity!);
    s.setFloat(i++, cfg.glareAngle!);
    s.setFloat(i++, cfg.blurEdge! ? 1 : 0);
    s.setFloat(i++, cfg.shadowBlur!);
    s.setFloat(i++, shadowIntensity);
    s.setFloat(i++, cfg.shadowOffset!.dx); // u_shadowOffset (y-down)
    s.setFloat(i++, cfg.shadowOffset!.dy);
    s.setFloat(i++, texRect.left); // u_cropOrigin
    s.setFloat(i++, texRect.top);
    // u_cropSize comes from the actual texture: toImageSync ceils
    // logical * dpr, so a fractional DPR can make the image one texel larger
    // than the requested rect, and the uv mapping must use the real extent.
    s.setFloat(i++, sharp.width.toDouble()); // u_cropSize
    s.setFloat(i++, sharp.height.toDouble());
    s.setImageSampler(0, blurred, filterQuality: FilterQuality.low);
    s.setImageSampler(1, sharp, filterQuality: FilterQuality.low);
  }

  /// Rebuilds the crop textures if the cached ones don't cover [needed] for
  /// the current generation (and, when compositing lower panes, the current
  /// glass epoch).
  void _ensureCropTextures(
    RenderGlassScope scope,
    Rect needed,
    Rect scopePx,
    List<_GlassEntry> lower,
    // Composites are keyed on the lower panes' own states, not the global
    // glass epoch: this pane's movement must not rebuild a crop whose
    // content (backdrop plus lower output) did not change.
    int lowerHash,
    int radius, // blur radius, device px
  ) {
    final dpr = scope.devicePixelRatio;
    final kind = lower.isEmpty ? 0 : 1;
    if (_texGen == scope.generation &&
        _texDpr == dpr &&
        _texRadius == radius &&
        _texKind == kind &&
        _texLowerHash == lowerHash &&
        _texCrop != null &&
        _texCrop!.left <= needed.left &&
        _texCrop!.top <= needed.top &&
        _texCrop!.right >= needed.right &&
        _texCrop!.bottom >= needed.bottom) {
      return;
    }
    assert(() {
      debugCropTextureBuilds++;
      return true;
    }());
    _dropCropTextures();
    // Snapped out to a grid so small movements keep hitting the cache. Where
    // the crop is clipped by the scope edge, clamp-to-edge sampling matches
    // the reference.
    final crop = Rect.fromLTRB(
      (needed.left / _cropGrid).floorToDouble() * _cropGrid,
      (needed.top / _cropGrid).floorToDouble() * _cropGrid,
      (needed.right / _cropGrid).ceilToDouble() * _cropGrid,
      (needed.bottom / _cropGrid).ceilToDouble() * _cropGrid,
    ).intersect(scopePx);

    if (lower.isEmpty) {
      _sharp = scope._captureRegion(crop);
    } else {
      // Composite the lower panes' recorded output over the backdrop, in
      // scope-logical coordinates rasterized at device resolution.
      final ui.Image base;
      final bool ownsBase;
      if (scope.isChurning) {
        base = scope._captureRegion(crop);
        ownsBase = true;
      } else {
        base = scope._sharpTexture();
        ownsBase = false;
      }
      final rec = ui.PictureRecorder();
      final c = Canvas(rec);
      c.scale(dpr);
      c.translate(-crop.left / dpr, -crop.top / dpr);
      c.drawImageRect(
        base,
        ownsBase
            ? Rect.fromLTWH(0, 0, base.width.toDouble(), base.height.toDouble())
            : crop,
        Rect.fromLTRB(
          crop.left / dpr,
          crop.top / dpr,
          crop.right / dpr,
          crop.bottom / dpr,
        ),
        Paint()..filterQuality = FilterQuality.low,
      );
      for (final e in lower) {
        final pic = e.picture;
        if (pic != null) c.drawPicture(pic);
        for (final cp in e.childPictures) {
          c.drawPicture(cp);
        }
      }
      final pic = rec.endRecording();
      _sharp = pic.toImageSync(crop.width.toInt(), crop.height.toInt());
      pic.dispose();
      if (ownsBase) base.dispose();
    }
    _blurred = radius <= 2 ? _sharp : RenderGlassScope._blur(_sharp!, radius);
    _texCrop = crop;
    _texGen = scope.generation;
    _texRadius = radius;
    _texDpr = dpr;
    _texKind = kind;
    _texLowerHash = lowerHash;
  }

  // ---- CanvasKit fallback: BackdropFilter pipeline, no capture/readbacks ----

  ui.FragmentShader? _overlayShader;

  // Retained across paints (same pattern as RenderBackdropFilter/magnifier).
  // LayerHandles keep the layers alive while dropped from the tree (e.g. an
  // impl flip).
  final LayerHandle<ClipPathLayer> _fbClip = LayerHandle<ClipPathLayer>();
  final LayerHandle<BackdropFilterLayer> _fbFilter =
      LayerHandle<BackdropFilterLayer>();

  void _releaseFbLayers() {
    _fbClip.layer = null;
    _fbFilter.layer = null;
  }

  // Lens magnification cache, keyed on the fields below.
  double _fbLens = 1;
  double _fbMinHalf = -1, _fbT = -1, _fbIor = -1;

  /// Reference edge factor at depth [nm] (1x px) inside the refraction band.
  static double _edgeFactorAt(double nm, double t, double refFactor) {
    if (refFactor <= 1 || t <= 0) return 0; // no refraction; avoids nm/0 NaN
    final xr = 1 - nm / t;
    final thetaI = math.asin((xr * xr).clamp(0.0, 1.0));
    final thetaT = math.asin(math.sin(thetaI) / refFactor);
    return -math.tan(thetaT - thetaI);
  }

  /// Magnification whose inward pull at the pane edge matches the reference's
  /// refraction displacement at half band depth (70.71 * edgeFactor logical
  /// px, see [_reachFor]), spread uniformly over the pane.
  double _lensScale() {
    final minHalf = math.min(size.width, size.height) / 2;
    final t = _settings.thickness!;
    final ior = _settings.indexOfRefraction!;
    if (_fbMinHalf != minHalf || _fbT != t || _fbIor != ior) {
      _fbLens =
          1 + 70.71 * _edgeFactorAt(t * 0.5, t, ior) / math.max(minHalf, 1);
      _fbMinHalf = minHalf;
      _fbT = t;
      _fbIor = ior;
    }
    return _fbLens;
  }

  /// Magnifying backdrop matrix with its fixed point at the glass center
  /// (same recipe as the framework's RawMagnifier: coordinates are this
  /// layer's paint space).
  ui.ImageFilter _magnifyFilter(Offset offset, double s) {
    final c = offset + size.center(Offset.zero);
    final m = Matrix4.identity()
      ..translateByDouble(c.dx * (1 - s), c.dy * (1 - s), 0, 1)
      ..scaleByDouble(s, s, 1, 1);
    return ui.ImageFilter.matrix(m.storage, filterQuality: FilterQuality.low);
  }

  static void _noopPaint(PaintingContext context, Offset offset) {}

  void _pushBackdrop(
    PaintingContext context,
    Offset offset,
    Path localPath,
    ui.ImageFilter filter,
  ) {
    _fbClip.layer ??= ClipPathLayer();
    _fbFilter.layer ??= BackdropFilterLayer();
    final clip = _fbClip.layer!..clipPath = localPath.shift(offset);
    final f = _fbFilter.layer!..filter = filter;
    context.pushLayer(
      clip,
      (ctx, off) => ctx.pushLayer(f, _noopPaint, off),
      offset,
    );
  }

  void _paintFallback(
    PaintingContext context,
    Offset offset,
    RenderGlassScope scope,
  ) {
    _dropCropTextures(); // frees capture-pipeline leftovers; no-op afterwards
    final glassPath = _glassPathFor(size); // also refreshes _pathR
    final shadowIntensity = _settings.shadowIntensity!;

    // Exterior-only drop shadow: the pane region must stay clear, or the
    // BackdropFilters would blur the shadow into the glass (the interior
    // term lives in the overlay shader, like the reference).
    if (shadowIntensity > 0) {
      final canvas = context.canvas;
      final blur = math.max(_settings.shadowBlur!, 0.1);
      final exterior = Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(((offset + _settings.shadowOffset!) & size).inflate(3 * blur))
        ..addPath(glassPath, offset);
      canvas.save();
      canvas.clipPath(exterior);
      _paintShadow(canvas, glassPath, offset, shadowIntensity);
      canvas.restore();
    }

    final dpr = scope.devicePixelRatio;
    final radius = _settings.blurRadius!;
    // device radius <= 2 is sub-pixel, same threshold as the capture
    // pipeline; sigma is in logical px (the compositor scales it by dpr)
    final ui.ImageFilter? blurF = radius * dpr > 2
        ? ui.ImageFilter.blur(
            sigmaX: radius / 3.0,
            sigmaY: radius / 3.0,
            tileMode: TileMode.clamp,
          )
        : null;

    ui.ImageFilter? f = blurF;
    final s = _lensScale();
    if (s > 1.0001) {
      final m = _magnifyFilter(offset, s);
      f = blurF == null ? m : ui.ImageFilter.compose(outer: m, inner: blurF);
    }
    if (f != null) _pushBackdrop(context, offset, glassPath, f);

    // lighting overlay (interior shadow, tint, fresnel, glare) on top;
    // re-fetch the canvas: pushLayer ended the previous recording
    final os = _overlayShader ??= _GlassShaders.overlay.fragmentShader();
    _setOverlayUniforms(os, scope, offset, shadowIntensity);
    final canvas = context.canvas;
    canvas.save();
    canvas.clipPath(glassPath.shift(offset));
    canvas.drawRect(offset & size, _glassPaint..shader = os);
    canvas.restore();

    _paintChild(context, offset);
  }

  void _setOverlayUniforms(
    ui.FragmentShader s,
    RenderGlassScope scope,
    Offset drawOrigin,
    double shadowIntensity,
  ) {
    final cfg = _settings;
    final dpr = scope.devicePixelRatio;
    var i = 0;
    s.setFloat(i++, (scope.size.width * dpr).ceilToDouble()); // u_scopeRes
    s.setFloat(i++, (scope.size.height * dpr).ceilToDouble());
    s.setFloat(i++, dpr); // u_dpr
    s.setFloat(i++, drawOrigin.dx); // u_drawOrigin
    s.setFloat(i++, drawOrigin.dy);
    s.setFloat(i++, size.width); // u_size
    s.setFloat(i++, size.height);
    s.setFloat(i++, _pathR); // u_shapeRadius
    s.setFloat(i++, cfg.shape!.roundness); // u_shapeRoundness
    final tint = cfg.tint!;
    s.setFloat(i++, tint.r); // u_tint
    s.setFloat(i++, tint.g);
    s.setFloat(i++, tint.b);
    s.setFloat(i++, tint.a);
    s.setFloat(i++, cfg.thickness!);
    s.setFloat(i++, cfg.indexOfRefraction!);
    s.setFloat(i++, cfg.fresnelRange!);
    s.setFloat(i++, cfg.fresnelHardness!);
    s.setFloat(i++, cfg.fresnelIntensity!);
    s.setFloat(i++, cfg.glareRange!);
    s.setFloat(i++, cfg.glareHardness!);
    s.setFloat(i++, cfg.glareConvergence!);
    s.setFloat(i++, cfg.glareOppositeIntensity!);
    s.setFloat(i++, cfg.glareIntensity!);
    s.setFloat(i++, cfg.glareAngle!);
    s.setFloat(i++, cfg.shadowBlur!);
    s.setFloat(i++, shadowIntensity);
    s.setFloat(i++, cfg.shadowOffset!.dx); // u_shadowOffset (y-down)
    s.setFloat(i++, cfg.shadowOffset!.dy);
  }

  @override
  void dispose() {
    _dropCropTextures();
    _shader?.dispose();
    _shader = null;
    _compShader?.dispose();
    _compShader = null;
    _overlayShader?.dispose();
    _overlayShader = null;
    _releaseFbLayers();
    _childClip.layer = null;
    super.dispose();
  }
}
