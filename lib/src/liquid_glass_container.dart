import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Loads the fragment programs once, shared by all containers.
class _GlassShaders {
  static late ui.FragmentProgram main;
  static late ui.FragmentProgram overlay;
  static Future<void>? _loading;

  static bool loaded = false;

  // Consumers address package shaders as packages/<pkg>/lib/... (the shaders
  // section keeps the full lib/ path, unlike images); when this package itself
  // is the root project (its own `flutter test`) the key is the raw lib/ path,
  // hence the fallback.
  static Future<ui.FragmentProgram> _load(String name) =>
      ui.FragmentProgram.fromAsset(
        'packages/liquid_glass_container/lib/shaders/$name',
      ).catchError((_) => ui.FragmentProgram.fromAsset('lib/shaders/$name'));

  static Future<void> ensureLoaded() => _loading ??= Future.wait([
    _load('glass_main.frag'),
    _load('glass_overlay.frag'),
  ]).then((ps) {
    main = ps[0];
    overlay = ps[1];
    loaded = true;
    _warmUp();
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

/// Canvas proxy that folds every draw command into the frame hash so the scope
/// can tell whether the backdrop recording actually changed. Objects without
/// content equality are folded by identity (+ cheap metrics): a false mismatch
/// only costs a recapture, never a stale backdrop. Mutable-without-identity
/// cases (FragmentShader uniforms) poison the hash instead.
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

  void _path(Path p) {
    // identity + bounds: paths are folded conservatively (see class doc)
    _i(identityHashCode(p));
    _rect(p.getBounds());
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
}

/// PaintingContext for the backdrop capture: skips glass containers (they are
/// the consumers of the capture, not part of it), records everything else
/// through a [_HashingCanvas] for change detection, and inlines repaint
/// boundaries and common layer effects so the capture is a self-contained
/// recording that never borrows layers from the live tree.
class _GlassCaptureContext extends PaintingContext {
  _GlassCaptureContext(super.layer, super.bounds, this._hasher, this._scope);

  final _FrameHasher _hasher;
  final RenderGlassScope _scope;
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
      _GlassCaptureContext(childLayer, bounds, _hasher, _scope);

  @override
  void paintChild(RenderObject child, Offset offset) {
    if (child is RenderLiquidGlassContainer) {
      // Glass never enters the backdrop, but the visit builds the paint-order
      // registry that drives glass-through-glass compositing.
      _scope._registerGlass(child, offset);
      return;
    }
    if (child.isRepaintBoundary) {
      // Inline the subtree instead of adopting its retained layer: keeps the
      // capture self-contained and lets the hash see the actual content.
      _hasher.addInt(36);
      _hasher.addDouble(offset.dx);
      _hasher.addDouble(offset.dy);
      child.paint(this, offset);
      return;
    }
    super.paintChild(child, offset);
  }

  @override
  void appendLayer(Layer layer) {
    // Unknown layer content (textures, platform views, custom layers) can't be
    // hashed or re-recorded: fall back to recapturing every frame.
    _hasher.poison();
    super.appendLayer(layer);
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

/// Wrap the app (or any subtree) once; every [LiquidGlassContainer] below it
/// samples this subtree's pixels as its backdrop.
///
/// The scope re-records the backdrop whenever the subtree repaints, but only
/// re-rasterizes (and bumps [RenderGlassScope.generation]) when the recorded
/// content actually changed — glass moving over a static backdrop reuses the
/// previous capture.
///
/// On CanvasKit builds (dart2js — `kIsWeb && !kIsWasm`) `toImageSync` is a
/// synchronous GPU readback, so the capture pipeline is replaced by a
/// BackdropFilter-based fallback: no capture, no readbacks; containers become
/// clipped backdrop-blur layers plus a backdrop-independent lighting shader.
class GlassBackdropScope extends SingleChildRenderObjectWidget {
  const GlassBackdropScope({
    super.key,
    this.fallbackOnCanvasKit = true,
    this.forceFallback = false,
    required super.child,
  });

  /// Use the BackdropFilter fallback when running on CanvasKit.
  final bool fallbackOnCanvasKit;

  /// Use the fallback on every backend (visual comparison / debugging).
  final bool forceFallback;

  @override
  RenderGlassScope createRenderObject(BuildContext context) => RenderGlassScope(
    View.of(context).devicePixelRatio,
    fallbackOnCanvasKit,
    forceFallback,
  );

  @override
  void updateRenderObject(BuildContext context, RenderGlassScope renderObject) {
    renderObject
      ..devicePixelRatio = View.of(context).devicePixelRatio
      ..setFallbackFlags(fallbackOnCanvasKit, forceFallback);
  }
}

class RenderGlassScope extends RenderProxyBox {
  RenderGlassScope(
    this._devicePixelRatio,
    bool fallbackOnCanvasKit,
    bool forceFallback,
  ) : _fallbackActive = _resolveFallback(fallbackOnCanvasKit, forceFallback);

  double _devicePixelRatio;
  double get devicePixelRatio => _devicePixelRatio;
  set devicePixelRatio(double value) {
    if (value == _devicePixelRatio) return;
    _devicePixelRatio = value;
    markNeedsPaint();
  }

  bool _fallbackActive;

  static bool _resolveFallback(bool onCanvasKit, bool force) =>
      force || (onCanvasKit && kIsWeb && !kIsWasm);

  /// Whether containers paint via the BackdropFilter fallback.
  bool get fallbackActive => _fallbackActive;

  void setFallbackFlags(bool onCanvasKit, bool force) {
    final active = _resolveFallback(onCanvasKit, force);
    if (active == _fallbackActive) return;
    _fallbackActive = active;
    if (active) {
      // capture machinery is dead weight while the fallback runs
      _clearEntries();
      _dropTextures();
      _captureLayer?.dispose();
      _captureLayer = null;
      _hashValid = false;
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
  bool capturing = false;

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
  List<int> _prevGlassStates = const [];

  /// Bumped whenever any glass container's geometry or parameters change;
  /// composite textures (which bake lower panes' output) are keyed on it.
  int _glassEpoch = 0;

  void _registerGlass(RenderLiquidGlassContainer c, Offset offsetLogical) {
    final dpr = _devicePixelRatio;
    final glassPx = (offsetLogical * dpr) & c.size * dpr;
    final cfg = c.config;
    // Overlap-test bounds are deliberately tight (glass body + AA margin, and
    // for sampling the blur smear): the theoretical refraction reach covers a
    // ~1px rim band at extreme angles — not worth per-frame compositing for
    // panes that merely sit near each other.
    final paintBounds = glassPx.inflate(2 * dpr);
    final sampleBounds = glassPx.inflate(8 * dpr + 2.0 * cfg.blurRadius);
    _entryIndex[c] = _entries.length;
    _entries.add(
      _GlassEntry(c, glassPx, paintBounds, sampleBounds, c._stateHash(glassPx)),
    );
  }

  void _clearEntries() {
    for (final e in _entries) {
      e.picture?.dispose();
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
  ui.Image captureRegion(Rect devicePxRect) => _captureLayer!.toImageSync(
    Rect.fromLTRB(
      devicePxRect.left / _devicePixelRatio,
      devicePxRect.top / _devicePixelRatio,
      devicePxRect.right / _devicePixelRatio,
      devicePxRect.bottom / _devicePixelRatio,
    ),
    pixelRatio: _devicePixelRatio,
  );

  /// Full-scope raster of the backdrop recording (device px).
  ui.Image sharpTexture() {
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
  ui.Image blurredTexture(int radius) {
    final sharp = sharpTexture(); // refreshes the cache key, drops stale blurs
    if (radius <= 2) return sharp;
    return _blurTexs[radius] ??= _blur(sharp, radius);
  }

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

    capturing = true;
    _clearEntries();
    final OffsetLayer captureLayer = OffsetLayer();
    final hasher = _FrameHasher();
    final captureContext = _GlassCaptureContext(
      captureLayer,
      Offset.zero & size,
      hasher,
      this,
    );
    super.paint(captureContext, Offset.zero);
    // Same pattern as the framework's SnapshotWidget.
    // ignore: invalid_use_of_protected_member
    captureContext.stopRecordingIfNeeded();
    capturing = false;

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

    // any glass geometry/param change invalidates composited textures
    final states = [for (final e in _entries) e.stateHash];
    if (!listEquals(states, _prevGlassStates)) {
      _glassEpoch++;
      _prevGlassStates = states;
    }

    super.paint(context, offset);
  }

  @override
  void dispose() {
    _clearEntries();
    _dropTextures();
    _captureLayer?.dispose();
    _captureLayer = null;
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

  /// This frame's recorded output (scope-logical coords), set by the
  /// container during its paint when a later pane needs to sample it.
  ui.Picture? picture;
}

/// A rounded rectangle with the liquid-glass effect, ported from
/// https://github.com/iyinchao/liquid-glass-studio (STEP 9 composite).
///
/// Must be a descendant of a [GlassBackdropScope]. Parameters mirror the
/// reference's control panel (same names, scales, and defaults).
///
/// The optional [child] is laid out within the glass (loose constraints,
/// centered — wrap it in [Align]/[Padding] for other placements) and painted
/// on top of the pane. It is never part of the backdrop, so it does not get
/// refracted or blurred. A lower pane's child is not visible through an
/// overlapping upper pane (only the glass itself composites through).
class LiquidGlassContainer extends SingleChildRenderObjectWidget {
  const LiquidGlassContainer({
    super.key,
    super.child,
    this.width = 200,
    this.height = 200,
    this.cornerRadius = 80, // % of min(width, height)/2
    this.roundness = 5, // superellipse corner exponent, 2..7
    this.refThickness = 20,
    this.refFactor = 1.4,
    this.refDispersion = 7,
    this.refFresnelRange = 30,
    this.refFresnelHardness = 20, // 0..100
    this.refFresnelFactor = 20, // 0..100
    this.glareRange = 30,
    this.glareHardness = 20, // 0..100
    this.glareFactor = 90, // 0..120
    this.glareConvergence = 50, // 0..100
    this.glareOppositeFactor = 80, // 0..100
    this.glareAngle = -45, // degrees
    this.blurRadius = 1, // device px, 1..200
    this.blurEdge = true,
    this.tint = const Color(0x00FFFFFF),
    this.shadowExpand = 25,
    this.shadowFactor = 15, // 0..100
    this.shadowPosition = const Offset(0, -10),
  });

  /// Optionally call before first build to avoid a blank first frame.
  static Future<void> precache() => _GlassShaders.ensureLoaded();

  final double width;
  final double height;
  final double cornerRadius;
  final double roundness;
  final double refThickness;
  final double refFactor;
  final double refDispersion;
  final double refFresnelRange;
  final double refFresnelHardness;
  final double refFresnelFactor;
  final double glareRange;
  final double glareHardness;
  final double glareFactor;
  final double glareConvergence;
  final double glareOppositeFactor;
  final double glareAngle;
  final int blurRadius;
  final bool blurEdge;
  final Color tint;
  final double shadowExpand;
  final double shadowFactor;
  final Offset shadowPosition;

  @override
  RenderLiquidGlassContainer createRenderObject(BuildContext context) =>
      RenderLiquidGlassContainer(this);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderLiquidGlassContainer renderObject,
  ) {
    renderObject.config = this;
  }
}

class RenderLiquidGlassContainer extends RenderBox
    with RenderObjectWithChildMixin<RenderBox> {
  RenderLiquidGlassContainer(this._config);

  LiquidGlassContainer _config;
  LiquidGlassContainer get config => _config;
  set config(LiquidGlassContainer value) {
    _config = value;
    markNeedsLayout();
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
  int _texEpoch = -1;

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

  @override
  void performLayout() {
    size = constraints.constrain(Size(_config.width, _config.height));
    final c = child;
    if (c != null) {
      c.layout(BoxConstraints.loose(size), parentUsesSize: true);
      (c.parentData! as BoxParentData).offset = Offset(
        (size.width - c.size.width) / 2,
        (size.height - c.size.height) / 2,
      );
    }
  }

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

  void _paintChild(PaintingContext context, Offset offset) {
    final c = child;
    if (c != null) {
      context.paintChild(c, offset + (c.parentData! as BoxParentData).offset);
    }
  }

  /// Superellipse-cornered rounded rect matching the shader's SDF; used for
  /// the AA edge clip and the drop shadow.
  Path _glassPathFor(Size s) {
    final r = (math.min(s.width, s.height) / 2 * _config.cornerRadius / 100)
        .clamp(0.0, math.min(s.width, s.height) / 2);
    final n = _config.roundness;
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
    if (scope.capturing || !scope.hasBackdrop) return;

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
    if (!glassPx.overlaps(scopePx)) return;

    // Sampled area (glass + refraction/dispersion/blur reach); lower panes
    // whose output lands inside it must show through this one.
    final needed = glassPx
        .inflate(_reachFor(_config, dpr).ceilToDouble())
        .intersect(scopePx);
    final lower = scope._lowerIntersecting(this);

    final ui.Image sharp;
    final ui.Image blurred;
    final Rect texRect; // u_cropOrigin/u_cropSize
    if (lower.isNotEmpty || scope.isChurning) {
      // Crop textures: when overlapped from below, the crop composites the
      // lower panes' recorded output over the backdrop (so this pane refracts
      // them); on an animated backdrop a crop is also far less readback data
      // per frame than the full scope.
      _ensureCropTextures(scope, needed, scopePx, lower);
      sharp = _sharp!;
      blurred = _blurred!;
      texRect = _texCrop!;
    } else {
      // Static backdrop, nothing underneath: shared full-scope textures,
      // position independent (sampling clamps at the scope edge, exactly
      // like the reference).
      _dropCropTextures();
      sharp = scope.sharpTexture();
      blurred = scope.blurredTexture(_config.blurRadius);
      texRect = scopePx;
    }

    final shadowFactor = _config.shadowFactor / 100;
    _setUniforms(
      _shader ??= _GlassShaders.main.fragmentShader(),
      scopePx,
      dpr,
      offset,
      originScope,
      texRect,
      sharp,
      blurred,
      shadowFactor,
    );
    _paintGlass(context.canvas, offset, _shader!, shadowFactor);

    // If a later pane samples this one, record the same output (in scope
    // coordinates) so it can be composited into that pane's backdrop.
    final entry = scope._entryOf(this);
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
        shadowFactor,
      );
      final rec = ui.PictureRecorder();
      _paintGlass(Canvas(rec), originLogical, ps, shadowFactor);
      entry.picture?.dispose();
      entry.picture = rec.endRecording();
    }

    _paintChild(context, offset);
  }

  /// Max sampling offset in device px: refraction (70.71 * cot(asin(1/n)) *
  /// dpr, per the shader's normal magnitude) times the dispersion scale, plus
  /// 2*blurRadius for the gaussian.
  static double _reachFor(LiquidGlassContainer cfg, double dpr) {
    final edgeFactorMax = cfg.refFactor <= 1
        ? 0.0
        : 1 / math.tan(math.asin(1 / cfg.refFactor));
    return 70.71 * edgeFactorMax * dpr * (1 + 0.02 * cfg.refDispersion) +
        2.0 * cfg.blurRadius +
        2;
  }

  /// Everything that determines this pane's rendered output (given the same
  /// backdrop); folded into the scope's glass epoch.
  int _stateHash(Rect glassPx) {
    final c = _config;
    return Object.hashAll([
      glassPx.left,
      glassPx.top,
      glassPx.right,
      glassPx.bottom,
      c.cornerRadius,
      c.roundness,
      c.refThickness,
      c.refFactor,
      c.refDispersion,
      c.refFresnelRange,
      c.refFresnelHardness,
      c.refFresnelFactor,
      c.glareRange,
      c.glareHardness,
      c.glareFactor,
      c.glareConvergence,
      c.glareOppositeFactor,
      c.glareAngle,
      c.blurRadius,
      c.blurEdge,
      c.tint,
      c.shadowExpand,
      c.shadowFactor,
      c.shadowPosition,
    ]);
  }

  /// Draws the drop shadow and the clipped glass rect at [drawOrigin] in the
  /// canvas's current space (scene: logical local px; recording: scope
  /// logical px).
  void _paintGlass(
    Canvas canvas,
    Offset drawOrigin,
    ui.FragmentShader shader,
    double shadowFactor,
  ) {
    final glassPath = _glassPathFor(size);

    // Drop shadow: the reference's exp(-|sdf|/expand) falloff, approximated
    // by a gaussian mask blur of the shape (deviation: gaussian tail, and
    // multiplicative rather than subtractive darkening).
    if (shadowFactor > 0) {
      _paintShadow(canvas, glassPath, drawOrigin, shadowFactor);
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
    double shadowFactor,
  ) {
    // reference offsets the shadow SDF by -shadowPosition in y-up coords
    final shift = Offset(_config.shadowPosition.dx, -_config.shadowPosition.dy);
    canvas.drawPath(
      glassPath.shift(drawOrigin + shift),
      Paint()
        ..color = Color.fromARGB(
          (255 * (0.6 * shadowFactor).clamp(0.0, 1.0)).round(),
          0,
          0,
          0,
        )
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          math.max(_config.shadowExpand, 0.1),
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
    double shadowFactor,
  ) {
    final cfg = _config;
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
    s.setFloat(i++, cfg.roundness); // u_shapeRoundness
    final tint = cfg.tint;
    s.setFloat(i++, tint.r); // u_tint
    s.setFloat(i++, tint.g);
    s.setFloat(i++, tint.b);
    s.setFloat(i++, tint.a);
    s.setFloat(i++, cfg.refThickness);
    s.setFloat(i++, cfg.refFactor);
    s.setFloat(i++, cfg.refDispersion);
    s.setFloat(i++, cfg.refFresnelRange);
    s.setFloat(i++, cfg.refFresnelHardness / 100);
    s.setFloat(i++, cfg.refFresnelFactor / 100);
    s.setFloat(i++, cfg.glareRange);
    s.setFloat(i++, cfg.glareHardness / 100);
    s.setFloat(i++, cfg.glareConvergence / 100);
    s.setFloat(i++, cfg.glareOppositeFactor / 100);
    s.setFloat(i++, cfg.glareFactor / 100);
    s.setFloat(i++, cfg.glareAngle * math.pi / 180);
    s.setFloat(i++, cfg.blurEdge ? 1 : 0);
    s.setFloat(i++, cfg.shadowExpand);
    s.setFloat(i++, shadowFactor);
    s.setFloat(i++, cfg.shadowPosition.dx); // u_shadowOffset (y-down)
    s.setFloat(i++, -cfg.shadowPosition.dy);
    s.setFloat(i++, texRect.left); // u_cropOrigin
    s.setFloat(i++, texRect.top);
    s.setFloat(i++, texRect.width); // u_cropSize
    s.setFloat(i++, texRect.height);
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
  ) {
    final dpr = scope.devicePixelRatio;
    final radius = _config.blurRadius;
    final kind = lower.isEmpty ? 0 : 1;
    if (_texGen == scope.generation &&
        _texDpr == dpr &&
        _texRadius == radius &&
        _texKind == kind &&
        (kind == 0 || _texEpoch == scope._glassEpoch) &&
        _texCrop != null &&
        _texCrop!.left <= needed.left &&
        _texCrop!.top <= needed.top &&
        _texCrop!.right >= needed.right &&
        _texCrop!.bottom >= needed.bottom) {
      return;
    }
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
      _sharp = scope.captureRegion(crop);
    } else {
      // Composite the lower panes' recorded output over the backdrop, in
      // scope-logical coordinates rasterized at device resolution.
      final ui.Image base;
      final bool ownsBase;
      if (scope.isChurning) {
        base = scope.captureRegion(crop);
        ownsBase = true;
      } else {
        base = scope.sharpTexture();
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
    _texEpoch = scope._glassEpoch;
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
    final cfg = _config;
    final minHalf = math.min(size.width, size.height) / 2;
    final t = cfg.refThickness;
    if (_fbMinHalf != minHalf || _fbT != t || _fbIor != cfg.refFactor) {
      _fbLens =
          1 +
          70.71 *
              _edgeFactorAt(t * 0.5, t, cfg.refFactor) /
              math.max(minHalf, 1);
      _fbMinHalf = minHalf;
      _fbT = t;
      _fbIor = cfg.refFactor;
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
    final shadowFactor = _config.shadowFactor / 100;

    // Exterior-only drop shadow: the pane region must stay clear, or the
    // BackdropFilters would blur the shadow into the glass (the interior
    // term lives in the overlay shader, like the reference).
    if (shadowFactor > 0) {
      final canvas = context.canvas;
      final blur = math.max(_config.shadowExpand, 0.1);
      final shift = Offset(
        _config.shadowPosition.dx,
        -_config.shadowPosition.dy,
      );
      final exterior = Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(((offset + shift) & size).inflate(3 * blur))
        ..addPath(glassPath, offset);
      canvas.save();
      canvas.clipPath(exterior);
      _paintShadow(canvas, glassPath, offset, shadowFactor);
      canvas.restore();
    }

    final dpr = scope.devicePixelRatio;
    final radius = _config.blurRadius;
    // radius <= 2 is sub-pixel at 1x, same threshold as the capture pipeline;
    // sigma is in logical px here (the compositor scales it by dpr)
    final ui.ImageFilter? blurF = radius > 2
        ? ui.ImageFilter.blur(
            sigmaX: radius / 3.0 / dpr,
            sigmaY: radius / 3.0 / dpr,
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
    _setOverlayUniforms(os, scope, offset, shadowFactor);
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
    double shadowFactor,
  ) {
    final cfg = _config;
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
    s.setFloat(i++, cfg.roundness); // u_shapeRoundness
    final tint = cfg.tint;
    s.setFloat(i++, tint.r); // u_tint
    s.setFloat(i++, tint.g);
    s.setFloat(i++, tint.b);
    s.setFloat(i++, tint.a);
    s.setFloat(i++, cfg.refThickness);
    s.setFloat(i++, cfg.refFactor);
    s.setFloat(i++, cfg.refFresnelRange);
    s.setFloat(i++, cfg.refFresnelHardness / 100);
    s.setFloat(i++, cfg.refFresnelFactor / 100);
    s.setFloat(i++, cfg.glareRange);
    s.setFloat(i++, cfg.glareHardness / 100);
    s.setFloat(i++, cfg.glareConvergence / 100);
    s.setFloat(i++, cfg.glareOppositeFactor / 100);
    s.setFloat(i++, cfg.glareFactor / 100);
    s.setFloat(i++, cfg.glareAngle * math.pi / 180);
    s.setFloat(i++, cfg.shadowExpand);
    s.setFloat(i++, shadowFactor);
    s.setFloat(i++, cfg.shadowPosition.dx); // u_shadowOffset (y-down)
    s.setFloat(i++, -cfg.shadowPosition.dy);
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
    super.dispose();
  }
}

