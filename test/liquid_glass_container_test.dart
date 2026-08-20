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
              child: const LiquidGlassContainer(),
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
                    refThickness: 40,
                    refDispersion: 30,
                    blurRadius: 60,
                    tint: Color(0x33FF8800),
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
    // centered within the default 200x200 pane at the surface center
    expect(tester.getCenter(find.byType(TextButton)), const Offset(300, 300));
    await tester.tap(find.byType(TextButton));
    expect(tapped, 1);
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
                      blurRadius: 40,
                      tint: Color(0x99FF6600),
                    ),
                  ),
                  const Positioned(
                    left: 220,
                    top: 140,
                    child: LiquidGlassContainer(),
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

  Widget fallbackApp({Widget? child}) => MaterialApp(
    home: Scaffold(
      body: GlassBackdropScope(
        forceFallback: true,
        child: Stack(
          fit: StackFit.expand,
          children: [
            CustomPaint(painter: _CheckerboardPainter()),
            Center(
              child: LiquidGlassContainer(
                blurRadius: 40,
                refThickness: 30,
                child: child,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  testWidgets('forceFallback renders BackdropFilter stack, never captures', (
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
            fallbackOnCanvasKit: false,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CustomPaint(painter: _CheckerboardPainter()),
                const Center(child: LiquidGlassContainer()),
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
