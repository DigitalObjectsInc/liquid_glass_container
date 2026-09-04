import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_container/liquid_glass_container.dart';

/// 20 logical-px checkerboard; [phase] shifts the grid horizontally so tests
/// can force a backdrop content change.
class _CheckerboardPainter extends CustomPainter {
  _CheckerboardPainter([this.phase = 0]);

  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    const cell = 20.0;
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final grey = Paint()..color = const Color(0xFFBFBFBF);
    final dx = phase % (2 * cell);
    for (var y = 0; y * cell < size.height; y++) {
      for (var x = (y.isEven ? 1 : 0) - 2; x * cell + dx < size.width; x += 2) {
        canvas.drawRect(
          Rect.fromLTWH(x * cell + dx, y * cell, cell, cell),
          grey,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_CheckerboardPainter oldDelegate) =>
      oldDelegate.phase != phase;
}

/// Movable glass over a phase-shiftable checkerboard, driven from tests via
/// the state exposed by [find.byType].
class _Harness extends StatefulWidget {
  const _Harness();

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  Offset pos = const Offset(200, 200);
  double phase = 0;

  void move(Offset p) => setState(() => pos = p);
  void shiftBackdrop() => setState(() => phase += 20);

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: GlassBackdropScope(
        child: Stack(
          fit: StackFit.expand,
          children: [
            CustomPaint(painter: _CheckerboardPainter(phase)),
            Positioned(
              left: pos.dx,
              top: pos.dy,
              child: const LiquidGlassContainer(width: 200, height: 200),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Draws a caller-owned (possibly mutated in place) path; [rev] forces the
/// repaint.
class _PathPainter extends CustomPainter {
  _PathPainter(this.path, this.rev);

  final Path path;
  final int rev;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(path, Paint()..color = const Color(0xFF2244AA));
  }

  @override
  bool shouldRepaint(_PathPainter oldDelegate) => oldDelegate.rev != rev;
}

Future<void> _setUp(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(600, 600));
  tester.view.physicalSize = const Size(1200, 1200);
  tester.view.devicePixelRatio = 2.0;
  await tester.runAsync(LiquidGlassContainer.precache);
}

RenderGlassScope _scope(WidgetTester tester) =>
    tester.renderObject<RenderGlassScope>(find.byType(GlassBackdropScope));

_HarnessState _harness(WidgetTester tester) =>
    tester.state<_HarnessState>(find.byType(_Harness));

void main() {
  testWidgets('glass renders without errors (strong params)', (tester) async {
    await _setUp(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GlassBackdropScope(
            child: Stack(
              fit: StackFit.expand,
              children: [
                CustomPaint(painter: _CheckerboardPainter()),
                const Center(
                  child: LiquidGlassContainer(
                    width: 300,
                    height: 200,
                    settings: LiquidGlassSettings(
                      thickness: 40,
                      dispersion: 30,
                      blurRadius: 30, // 60 device px at dpr 2
                      tint: Color(0x33FF8800),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(_scope(tester).hasBackdrop, isTrue);
  });

  testWidgets('child renders centered and receives taps', (tester) async {
    await _setUp(tester);
    var tapped = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GlassBackdropScope(
            child: Stack(
              fit: StackFit.expand,
              children: [
                CustomPaint(painter: _CheckerboardPainter()),
                Center(
                  child: LiquidGlassContainer(
                    child: TextButton(
                      onPressed: () => tapped++,
                      child: const Text('press'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('press'), findsOneWidget);
    // pane wraps the child, centered at the surface center
    expect(tester.getCenter(find.byType(TextButton)), const Offset(300, 300));
    await tester.tap(find.byType(TextButton));
    expect(tapped, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('container sizing: wraps child + padding, expands childless', (
    tester,
  ) async {
    await _setUp(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GlassBackdropScope(
            child: Stack(
              fit: StackFit.expand,
              children: [
                CustomPaint(painter: _CheckerboardPainter()),
                const Center(
                  child: LiquidGlassContainer(
                    padding: EdgeInsets.all(20),
                    child: SizedBox(width: 100, height: 50),
                  ),
                ),
                const Positioned(
                  left: 0,
                  top: 0,
                  width: 300,
                  height: 240,
                  child: LiquidGlassContainer(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final panes = find.byType(LiquidGlassContainer);
    expect(tester.getSize(panes.first), const Size(140, 90));
    expect(tester.getSize(panes.last), const Size(300, 240));
    expect(tester.takeException(), isNull);
  });

  testWidgets('scope settings are inherited and overridden field-wise', (
    tester,
  ) async {
    await _setUp(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GlassBackdropScope(
            settings: const LiquidGlassSettings(thickness: 42, dispersion: 12),
            child: Stack(
              fit: StackFit.expand,
              children: [
                CustomPaint(painter: _CheckerboardPainter()),
                const Center(
                  child: LiquidGlassContainer(
                    width: 200,
                    height: 200,
                    settings: LiquidGlassSettings(dispersion: 3),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final pane = tester.renderObject<RenderLiquidGlassContainer>(
      find.byType(LiquidGlassContainer),
    );
    expect(pane.settings.thickness, 42); // from the scope
    expect(pane.settings.dispersion, 3); // container override wins
    expect(
      pane.settings.indexOfRefraction,
      LiquidGlassSettings.defaults.indexOfRefraction,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('pane hit-tests its shape: absorbs inside, corners pass', (
    tester,
  ) async {
    await _setUp(tester);
    var behind = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GlassBackdropScope(
            child: Stack(
              fit: StackFit.expand,
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => behind++,
                ),
                const Center(
                  child: LiquidGlassContainer(width: 200, height: 200),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // pane interior absorbs the tap
    await tester.tapAt(const Offset(300, 300));
    expect(behind, 0);
    // pane corner (outside the superellipse outline) passes through
    await tester.tapAt(const Offset(202, 202));
    expect(behind, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('static backdrop capture is reused while glass moves', (
    tester,
  ) async {
    await _setUp(tester);
    await tester.pumpWidget(const _Harness());
    await tester.pump();
    final scope = _scope(tester);
    final genBefore = scope.generation;
    expect(genBefore, greaterThan(0));

    // glass moves every frame, but the checkerboard is unchanged, so the
    // capture (and generation) must be reused
    final h = _harness(tester);
    for (var i = 0; i < 30; i++) {
      h.move(Offset(100.0 + i * 3, 150.0 + i * 2));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(scope.generation, genBefore);
    expect(tester.takeException(), isNull);
  });

  testWidgets('backdrop content change bumps the capture generation', (
    tester,
  ) async {
    await _setUp(tester);
    await tester.pumpWidget(const _Harness());
    await tester.pump();
    final scope = _scope(tester);
    final genBefore = scope.generation;
    _harness(tester).shiftBackdrop();
    await tester.pump();
    await tester.pump();
    expect(scope.generation, greaterThan(genBefore));
    expect(tester.takeException(), isNull);
  });

  testWidgets('texture strategy follows backdrop churn', (tester) async {
    await _setUp(tester);
    await tester.pumpWidget(const _Harness());
    await tester.pump();
    final scope = _scope(tester);
    // the very first capture counts as a bump, so churn mode starts on
    expect(scope.isChurning, isTrue);

    // a long stretch of stable repaints (moving glass) settles it back to
    // the shared full-scope textures
    final h = _harness(tester);
    for (var i = 0; i < 40; i++) {
      h.move(Offset(100.0 + i * 2, 150.0 + i));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(scope.isChurning, isFalse);

    // a backdrop content change flips it back to crop mode
    h.shiftBackdrop();
    await tester.pump();
    expect(scope.isChurning, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('lower glass shows through an overlapping pane', (tester) async {
    await _setUp(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          child: Scaffold(
            body: GlassBackdropScope(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CustomPaint(painter: _CheckerboardPainter()),
                  // strongly tinted pane below, clear pane on top
                  const Positioned(
                    left: 100,
                    top: 100,
                    child: LiquidGlassContainer(
                      width: 200,
                      height: 200,
                      settings: LiquidGlassSettings(
                        blurRadius: 20, // 40 device px at dpr 2
                        tint: Color(0x99FF6600),
                      ),
                    ),
                  ),
                  const Positioned(
                    left: 220,
                    top: 140,
                    child: LiquidGlassContainer(width: 200, height: 200),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byType(RepaintBoundary).first,
    );
    final image = await tester.runAsync(() => boundary.toImage());
    final data = await tester.runAsync(
      () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    int channel(int x, int y, int c) =>
        data!.getUint8((y * image!.width + x) * 4 + c);
    // inside the overlap (interior of both panes): the top pane must refract
    // the orange pane beneath it, so red must clearly dominate blue
    final rOverlap = channel(265, 230, 0), bOverlap = channel(265, 230, 2);
    expect(rOverlap - bOverlap, greaterThan(30));
    // top pane's non-overlapping interior stays untinted checkerboard
    final rPlain = channel(390, 230, 0), bPlain = channel(390, 230, 2);
    expect((rPlain - bPlain).abs(), lessThan(10));
    expect(tester.takeException(), isNull);
  });

  testWidgets('lower pane child is sampled through an overlapping pane', (
    tester,
  ) async {
    await _setUp(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          child: Scaffold(
            body: GlassBackdropScope(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CustomPaint(painter: _CheckerboardPainter()),
                  // lower pane filled by an opaque red child
                  Positioned(
                    left: 100,
                    top: 100,
                    child: LiquidGlassContainer(
                      width: 200,
                      height: 200,
                      child: Container(color: const Color(0xFFFF0000)),
                    ),
                  ),
                  const Positioned(
                    left: 220,
                    top: 140,
                    child: LiquidGlassContainer(width: 200, height: 200),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byType(RepaintBoundary).first,
    );
    final image = await tester.runAsync(() => boundary.toImage());
    final data = await tester.runAsync(
      () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    int channel(int x, int y, int c) =>
        data!.getUint8((y * image!.width + x) * 4 + c);
    // interior of the top pane over the red child: the child must show
    // through the upper glass
    final rOverlap = channel(280, 250, 0), bOverlap = channel(280, 250, 2);
    expect(rOverlap - bOverlap, greaterThan(60));
    // top pane's interior past the lower pane stays neutral checkerboard
    final rPlain = channel(390, 230, 0), bPlain = channel(390, 230, 2);
    expect((rPlain - bPlain).abs(), lessThan(10));
    expect(tester.takeException(), isNull);
  });

  testWidgets('child content change refreshes what the upper pane shows', (
    tester,
  ) async {
    await _setUp(tester);
    var childColor = const Color(0xFFFF0000);
    late StateSetter setColor;
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          child: Scaffold(
            body: GlassBackdropScope(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CustomPaint(painter: _CheckerboardPainter()),
                  Positioned(
                    left: 100,
                    top: 100,
                    child: LiquidGlassContainer(
                      width: 200,
                      height: 200,
                      child: StatefulBuilder(
                        builder: (context, setState) {
                          setColor = setState;
                          return Container(color: childColor);
                        },
                      ),
                    ),
                  ),
                  const Positioned(
                    left: 220,
                    top: 140,
                    child: LiquidGlassContainer(width: 200, height: 200),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    setColor(() => childColor = const Color(0xFF0000FF));
    await tester.pump();
    await tester.pump();

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byType(RepaintBoundary).first,
    );
    final image = await tester.runAsync(() => boundary.toImage());
    final data = await tester.runAsync(
      () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    int channel(int x, int y, int c) =>
        data!.getUint8((y * image!.width + x) * 4 + c);
    // the upper pane must show the child's new blue, not a stale red crop
    final r = channel(280, 250, 0), b = channel(280, 250, 2);
    expect(b - r, greaterThan(60));
    expect(tester.takeException(), isNull);
  });

  Widget fallbackApp({Widget? child}) => MaterialApp(
    home: Scaffold(
      body: GlassBackdropScope(
        renderMode: GlassRenderMode.backdropFilter,
        child: Stack(
          fit: StackFit.expand,
          children: [
            CustomPaint(painter: _CheckerboardPainter()),
            Center(
              child: LiquidGlassContainer(
                width: 200,
                height: 200,
                settings: const LiquidGlassSettings(
                  blurRadius: 20, // 40 device px at dpr 2
                  thickness: 30,
                ),
                child: child,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  testWidgets('backdropFilter mode renders BackdropFilter stack, never '
      'captures', (
    tester,
  ) async {
    await _setUp(tester);
    await tester.pumpWidget(fallbackApp(child: const Text('on glass')));
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    final scope = _scope(tester);
    expect(scope.fallbackActive, isTrue);
    expect(scope.hasBackdrop, isFalse);
    expect(scope.generation, 0);
    // one compose(magnify, blur) backdrop layer per pane
    expect(tester.layers.whereType<BackdropFilterLayer>().length, 1);
    // child paints on top of the fallback layers
    expect(find.text('on glass'), findsOneWidget);
  });

  testWidgets('fallback flag flips cleanly at runtime', (tester) async {
    await _setUp(tester);
    await tester.pumpWidget(fallbackApp());
    await tester.pump();
    expect(_scope(tester).hasBackdrop, isFalse);

    // full impl: capture resumes
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GlassBackdropScope(
            renderMode: GlassRenderMode.capture,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CustomPaint(painter: _CheckerboardPainter()),
                const Center(
                  child: LiquidGlassContainer(width: 200, height: 200),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final scope = _scope(tester);
    expect(scope.fallbackActive, isFalse);
    expect(scope.hasBackdrop, isTrue);
    expect(scope.generation, greaterThan(0));
    expect(tester.layers.whereType<BackdropFilterLayer>(), isEmpty);

    // and back to fallback: capture resources released
    await tester.pumpWidget(fallbackApp());
    await tester.pump();
    expect(_scope(tester).fallbackActive, isTrue);
    expect(_scope(tester).hasBackdrop, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('backdrop change inside a descendant RepaintBoundary '
      'recaptures', (tester) async {
    await _setUp(tester);
    var color = const Color(0xFFFFFFFF);
    late StateSetter setColor;
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          child: Scaffold(
            body: GlassBackdropScope(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // backdrop isolated behind its own boundary: its repaints
                  // never mark the scope dirty
                  RepaintBoundary(
                    child: StatefulBuilder(
                      builder: (context, setState) {
                        setColor = setState;
                        return ColoredBox(color: color);
                      },
                    ),
                  ),
                  const Positioned(
                    left: 100,
                    top: 100,
                    child: LiquidGlassContainer(width: 200, height: 200),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final scope = _scope(tester);
    final genBefore = scope.generation;

    setColor(() => color = const Color(0xFF000000));
    await tester.pump(); // boundary repaints; post-frame watcher detects
    await tester.pump(); // scope recaptures
    expect(scope.generation, greaterThan(genBefore));

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byType(RepaintBoundary).first,
    );
    final image = await tester.runAsync(() => boundary.toImage());
    final data = await tester.runAsync(
      () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    int lum(int x, int y) => data!.getUint8((y * image!.width + x) * 4);
    // the glass interior must refract the new black, not the stale white
    expect(lum(200, 200), lessThan(50));
    expect(tester.takeException(), isNull);
  });

  testWidgets('scrolling a list under glass recaptures', (tester) async {
    await _setUp(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GlassBackdropScope(
            child: Stack(
              children: [
                // viewport and items are repaint boundaries
                ListView.builder(
                  itemExtent: 50,
                  itemCount: 100,
                  itemBuilder: (context, i) => ColoredBox(
                    color: i.isEven
                        ? const Color(0xFFFFFFFF)
                        : const Color(0xFF808080),
                  ),
                ),
                const Positioned(
                  left: 20,
                  top: 20,
                  child: LiquidGlassContainer(width: 150, height: 150),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final scope = _scope(tester);
    final genBefore = scope.generation;

    await tester.drag(find.byType(ListView), const Offset(0, -120));
    await tester.pump(); // viewport repainted; watcher detects
    await tester.pump(); // scope recaptures
    expect(scope.generation, greaterThan(genBefore));
    expect(tester.takeException(), isNull);
  });

  testWidgets('composited opacity change under glass recaptures with the '
      'right alpha', (tester) async {
    await _setUp(tester);
    final controller = AnimationController(
      vsync: const TestVSync(),
      value: 0.5,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          child: Scaffold(
            body: GlassBackdropScope(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const ColoredBox(color: Color(0xFFFFFFFF)),
                  // RenderAnimatedOpacity: a repaint boundary whose alpha
                  // lives in its composited layer, not in a picture
                  FadeTransition(
                    opacity: controller,
                    child: const ColoredBox(color: Color(0xFF000000)),
                  ),
                  const Positioned(
                    left: 100,
                    top: 100,
                    child: LiquidGlassContainer(width: 200, height: 200),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(); // settle the first-frame uncomposited recapture
    final scope = _scope(tester);
    final genBefore = scope.generation;

    controller.value = 0.9; // composited-layer update only, no repaint
    await tester.pump();
    await tester.pump();
    expect(scope.generation, greaterThan(genBefore));

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byType(RepaintBoundary).first,
    );
    final image = await tester.runAsync(() => boundary.toImage());
    final data = await tester.runAsync(
      () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    int lum(int x, int y) => data!.getUint8((y * image!.width + x) * 4);
    // 0.9 black over white ~= 25; a capture stuck at 0.5 would read ~127,
    // one ignoring opacity entirely ~0 is not distinguishable — the alpha
    // matters, so assert the refracted value tracks it
    expect(lum(200, 200), lessThan(60));
    expect(tester.takeException(), isNull);
  });

  testWidgets('dry layout and intrinsics match Container semantics', (
    tester,
  ) async {
    await _setUp(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GlassBackdropScope(
            child: Stack(
              fit: StackFit.expand,
              children: [
                CustomPaint(painter: _CheckerboardPainter()),
                const Center(
                  child: LiquidGlassContainer(
                    padding: EdgeInsets.all(20),
                    child: SizedBox(width: 100, height: 50),
                  ),
                ),
                const Positioned(
                  left: 0,
                  top: 0,
                  child: LiquidGlassContainer(width: 300, height: 200),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final panes = tester
        .renderObjectList<RenderLiquidGlassContainer>(
          find.byType(LiquidGlassContainer),
        )
        .toList();
    final wrapping = panes[0];
    final fixed = panes[1];

    // dry layout mirrors performLayout
    const loose = BoxConstraints(maxWidth: 600, maxHeight: 600);
    expect(wrapping.getDryLayout(loose), const Size(140, 90));
    expect(wrapping.getDryLayout(loose), wrapping.size);
    expect(fixed.getDryLayout(loose), const Size(300, 200));

    // intrinsics: child + padding, or the explicit dimension
    expect(wrapping.getMinIntrinsicWidth(double.infinity), 140);
    expect(wrapping.getMaxIntrinsicWidth(double.infinity), 140);
    expect(wrapping.getMinIntrinsicHeight(double.infinity), 90);
    expect(wrapping.getMaxIntrinsicHeight(double.infinity), 90);
    expect(fixed.getMinIntrinsicWidth(double.infinity), 300);
    expect(fixed.getMaxIntrinsicHeight(double.infinity), 200);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pane participates in IntrinsicHeight and baseline rows', (
    tester,
  ) async {
    await _setUp(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GlassBackdropScope(
            child: Stack(
              fit: StackFit.expand,
              children: [
                CustomPaint(painter: _CheckerboardPainter()),
                Center(
                  child: IntrinsicHeight(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        SizedBox(width: 40, height: 30),
                        LiquidGlassContainer(
                          padding: EdgeInsets.all(10),
                          child: SizedBox(width: 20, height: 60),
                        ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  bottom: 0,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Text('A', style: TextStyle(fontSize: 20)),
                      LiquidGlassContainer(
                        padding: EdgeInsets.all(12),
                        child: Text('B', style: TextStyle(fontSize: 20)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    // IntrinsicHeight sizes to the pane's intrinsic height (60 + 20 padding)
    expect(tester.getSize(find.byType(IntrinsicHeight)).height, 80);
    // baseline row: glass text's on-screen baseline matches its sibling's
    expect(
      tester.getTopLeft(find.text('B')).dy,
      tester.getTopLeft(find.text('A')).dy,
    );
  });

  testWidgets('animated blur radius keeps the blur texture cache bounded', (
    tester,
  ) async {
    await _setUp(tester);
    var radius = 5.0;
    late StateSetter setRadius;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GlassBackdropScope(
            child: Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: Color(0xFFFFFFFF)),
                Positioned(
                  left: 100,
                  top: 100,
                  child: StatefulBuilder(
                    builder: (context, setState) {
                      setRadius = setState;
                      return LiquidGlassContainer(
                        width: 200,
                        height: 200,
                        settings: LiquidGlassSettings(blurRadius: radius),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // static backdrop, changing radius: churn mode exits after the stable
    // stretch and the shared full-scope blur cache takes over
    for (var r = 5; r <= 60; r++) {
      setRadius(() => radius = r.toDouble());
      await tester.pump(const Duration(milliseconds: 16));
    }
    final scope = _scope(tester);
    expect(scope.isChurning, isFalse);
    expect(scope.debugBlurTextureCount, greaterThan(0));
    expect(scope.debugBlurTextureCount, lessThanOrEqualTo(8));
    expect(tester.takeException(), isNull);
  });

  testWidgets('retained composited layers in a clean boundary stay on '
      'screen', (tester) async {
    await _setUp(tester);
    const invert = ColorFilter.matrix([
      -1, 0, 0, 0, 255, //
      0, -1, 0, 0, 255, //
      0, 0, -1, 0, 255, //
      0, 0, 0, 1, 0, //
    ]);
    var paneLeft = 400.0;
    late StateSetter setPaneLeft;
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          child: Scaffold(
            body: GlassBackdropScope(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const ColoredBox(color: Color(0xFFFFFFFF)),
                  // content that pushes retained composited layers, isolated
                  // behind its own boundary
                  Positioned(
                    left: 60,
                    top: 60,
                    width: 120,
                    height: 90,
                    child: RepaintBoundary(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          const Positioned(
                            left: 0,
                            top: 0,
                            width: 120,
                            height: 40,
                            child: ColorFiltered(
                              colorFilter: invert,
                              child: ColoredBox(color: Color(0xFFFF0000)),
                            ),
                          ),
                          Positioned(
                            left: 0,
                            top: 50,
                            width: 120,
                            height: 40,
                            child: ClipRect(
                              child: BackdropFilter(
                                filter: ui.ImageFilter.blur(
                                  sigmaX: 4,
                                  sigmaY: 4,
                                ),
                                child: const ColoredBox(
                                  color: Color(0x8800FF00),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  StatefulBuilder(
                    builder: (context, setState) {
                      setPaneLeft = setState;
                      return Positioned(
                        left: paneLeft,
                        top: 400,
                        child: const LiquidGlassContainer(
                          width: 150,
                          height: 150,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byType(RepaintBoundary).first,
      );
      final image = await tester.runAsync(() => boundary.toImage());
      final data = await tester.runAsync(
        () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
      );
      int ch(int x, int y, int c) =>
          data!.getUint8((y * image!.width + x) * 4 + c);
      // sanity: the content is on screen before the clean-boundary reuse
      expect(ch(120, 80, 0), lessThan(60));
    }
    // scope repaints while the boundary is clean: the capture must not steal
    // the boundary's retained layers
    setPaneLeft(() => paneLeft = 410);
    await tester.pump();
    await tester.pump();

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byType(RepaintBoundary).first,
    );
    final image = await tester.runAsync(() => boundary.toImage());
    final data = await tester.runAsync(
      () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    int ch(int x, int y, int c) =>
        data!.getUint8((y * image!.width + x) * 4 + c);
    // inverted red box must read cyan, not the white backdrop
    expect(ch(120, 80, 0), lessThan(60)); // r
    expect(ch(120, 80, 1), greaterThan(200)); // g
    // semi-green box over the backdrop filter must still be green-tinted
    expect(ch(120, 130, 1) - ch(120, 130, 0), greaterThan(40));
    expect(tester.takeException(), isNull);
  });

  testWidgets('pane inside a clean boundary follows backdrop changes', (
    tester,
  ) async {
    await _setUp(tester);
    var color = const Color(0xFFFFFFFF);
    late StateSetter setColor;
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          child: Scaffold(
            body: GlassBackdropScope(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  StatefulBuilder(
                    builder: (context, setState) {
                      setColor = setState;
                      return ColoredBox(color: color);
                    },
                  ),
                  const Positioned(
                    left: 100,
                    top: 100,
                    child: RepaintBoundary(
                      child: LiquidGlassContainer(width: 200, height: 200),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    setColor(() => color = const Color(0xFF000000));
    await tester.pump(); // scope recaptures, pane's boundary is clean
    await tester.pump(); // post-frame check marks the stale pane
    await tester.pump(); // pane repaints with the new texture

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byType(RepaintBoundary).first,
    );
    final image = await tester.runAsync(() => boundary.toImage());
    final data = await tester.runAsync(
      () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    int lum(int x, int y) => data!.getUint8((y * image!.width + x) * 4);
    // the glass interior must show the new black, not stale white
    expect(lum(200, 200), lessThan(50));
    expect(tester.takeException(), isNull);
  });

  testWidgets('in-place path mutation invalidates the capture', (tester) async {
    await _setUp(tester);
    final path = Path()..addRect(const Rect.fromLTWH(100, 100, 100, 100));
    var rev = 0;
    late StateSetter repaint;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GlassBackdropScope(
            child: Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: Color(0xFFFFFFFF)),
                StatefulBuilder(
                  builder: (context, setState) {
                    repaint = setState;
                    return CustomPaint(painter: _PathPainter(path, rev));
                  },
                ),
                const Positioned(
                  left: 300,
                  top: 300,
                  child: LiquidGlassContainer(width: 150, height: 150),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final scope = _scope(tester);
    final genBefore = scope.generation;

    // same identity, same bounds, different geometry
    repaint(() {
      rev++;
      path
        ..reset()
        ..addOval(const Rect.fromLTWH(100, 100, 100, 100));
    });
    await tester.pump();
    await tester.pump();
    expect(scope.generation, greaterThan(genBefore));
    expect(tester.takeException(), isNull);
  });

  testWidgets('glass moving over Material (fresh identical paths) reuses '
      'the capture', (tester) async {
    await _setUp(tester);
    var paneLeft = 350.0;
    late StateSetter setPaneLeft;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GlassBackdropScope(
            child: Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: Color(0xFFFFFFFF)),
                const Positioned(
                  left: 80,
                  top: 80,
                  child: Card(
                    elevation: 4,
                    child: SizedBox(width: 140, height: 90),
                  ),
                ),
                StatefulBuilder(
                  builder: (context, setState) {
                    setPaneLeft = setState;
                    return Positioned(
                      left: paneLeft,
                      top: 300,
                      child: const LiquidGlassContainer(
                        width: 150,
                        height: 150,
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final scope = _scope(tester);
    final genBefore = scope.generation;

    for (var i = 1; i <= 5; i++) {
      setPaneLeft(() => paneLeft = 350.0 + i * 4);
      await tester.pump(const Duration(milliseconds: 16));
    }
    // PhysicalShape allocates a fresh (identical) path per paint: the
    // content hash must match, so the capture is reused
    expect(scope.generation, genBefore);
    expect(tester.takeException(), isNull);
  });

  testWidgets('scope resize with identical draw commands recaptures', (
    tester,
  ) async {
    await _setUp(tester);
    var side = 400.0;
    late StateSetter setSide;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: StatefulBuilder(
              builder: (context, setState) {
                setSide = setState;
                return SizedBox(
                  width: side,
                  height: side,
                  child: GlassBackdropScope(
                    child: Stack(
                      fit: StackFit.expand,
                      children: const [
                        Positioned(
                          left: 0,
                          top: 0,
                          width: 100,
                          height: 100,
                          child: ColoredBox(color: Color(0xFFFFFFFF)),
                        ),
                        Positioned(
                          left: 20,
                          top: 20,
                          child: LiquidGlassContainer(width: 100, height: 100),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final scope = _scope(tester);
    final genBefore = scope.generation;
    setSide(() => side = 500);
    await tester.pump();
    await tester.pump();
    expect(scope.generation, greaterThan(genBefore));
    expect(tester.takeException(), isNull);
  });

  testWidgets('thickness 0 renders without artifacts', (tester) async {
    await _setUp(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          child: Scaffold(
            body: GlassBackdropScope(
              child: Stack(
                fit: StackFit.expand,
                children: const [
                  ColoredBox(color: Color(0xFFFFFFFF)),
                  Positioned(
                    left: 100,
                    top: 100,
                    child: LiquidGlassContainer(
                      width: 200,
                      height: 200,
                      settings: LiquidGlassSettings(thickness: 0),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byType(RepaintBoundary).first,
    );
    final image = await tester.runAsync(() => boundary.toImage());
    final data = await tester.runAsync(
      () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    int lum(int x, int y) => data!.getUint8((y * image!.width + x) * 4);
    // interior over white stays white; a NaN ring would corrupt the fringe
    expect(lum(200, 200), greaterThan(200));
    expect(lum(102, 200), greaterThan(150)); // just inside the left edge
    expect(tester.takeException(), isNull);
  });

  testWidgets('upper pane movement reuses the composite crop', (tester) async {
    await _setUp(tester);
    var upperLeft = 220.0;
    late StateSetter setUpperLeft;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GlassBackdropScope(
            child: Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: Color(0xFFFFFFFF)),
                const Positioned(
                  left: 100,
                  top: 100,
                  child: LiquidGlassContainer(width: 200, height: 200),
                ),
                StatefulBuilder(
                  builder: (context, setState) {
                    setUpperLeft = setState;
                    return Positioned(
                      left: upperLeft,
                      top: 140,
                      child: const LiquidGlassContainer(
                        width: 200,
                        height: 200,
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    RenderLiquidGlassContainer.debugCropTextureBuilds = 0;
    for (var i = 1; i <= 5; i++) {
      setUpperLeft(() => upperLeft = 220.0 + i * 2);
      await tester.pump(const Duration(milliseconds: 16));
    }
    // the crop content (backdrop + lower pane) did not change: the upper
    // pane's own movement must not rebuild it (1 allowed for a grid cross)
    expect(
      RenderLiquidGlassContainer.debugCropTextureBuilds,
      lessThanOrEqualTo(1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('nested scopes assert in debug', (tester) async {
    await _setUp(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: GlassBackdropScope(
          child: GlassBackdropScope(child: Container()),
        ),
      ),
    );
    expect(tester.takeException(), isFlutterError);
  });
}
