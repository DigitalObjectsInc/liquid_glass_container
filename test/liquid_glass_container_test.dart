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
}
