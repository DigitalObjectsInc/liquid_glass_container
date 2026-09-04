// Generates the package screenshots in ../doc/ from real rendered frames
// (the shaders run in the test environment). Skipped unless requested:
//
//   GENERATE_SCREENSHOTS=1 flutter test test/screenshot_test.dart

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_container/liquid_glass_container.dart';
import 'package:liquid_glass_container_example/main.dart';

const _size = Size(1440, 900);

Future<void> _shoot(
  WidgetTester tester,
  String file,
  String asset,
  double aspect,
  List<Widget> panes,
) async {
  await tester.binding.setSurfaceSize(_size);
  tester.view.physicalSize = _size * 2;
  tester.view.devicePixelRatio = 2.0;
  await tester.runAsync(LiquidGlassContainer.precache);
  await tester.pumpWidget(
    MaterialApp(
      home: RepaintBoundary(
        child: Scaffold(
          body: GlassBackdropScope(
            child: Stack(
              fit: StackFit.expand,
              children: [
                MirrorTiledImage(asset: asset, aspect: aspect),
                ...panes,
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.runAsync(() async {
    final ctx = tester.element(find.byType(Scaffold));
    await precacheImage(AssetImage(asset), ctx);
  });
  await tester.pump();
  await tester.pump();
  await tester.pump();
  expect(tester.takeException(), isNull);

  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byType(RepaintBoundary).first,
  );
  final image = await tester.runAsync(() => boundary.toImage(pixelRatio: 2));
  final data = await tester.runAsync(
    () => image!.toByteData(format: ui.ImageByteFormat.png),
  );
  final out = File('../doc/$file');
  out.parent.createSync(recursive: true);
  out.writeAsBytesSync(data!.buffer.asUint8List());
  debugPrint('wrote ${out.path} (${data.lengthInBytes ~/ 1024} KB)');
}

void main() {
  final enabled = Platform.environment['GENERATE_SCREENSHOTS'] == '1';

  testWidgets('hero screenshot', skip: !enabled, (tester) async {
    await _shoot(tester, 'hero.png', 'assets/bg-tahoe-light.webp', 1, const [
      // main pane
      Positioned(
        left: 420,
        top: 250,
        child: LiquidGlassContainer(
          width: 380,
          height: 260,
          settings: LiquidGlassSettings(blurRadius: 6),
        ),
      ),
      // overlapping tinted pane: glass on glass
      Positioned(
        left: 680,
        top: 420,
        child: LiquidGlassContainer(
          width: 300,
          height: 210,
          settings: LiquidGlassSettings(
            tint: Color(0x33FFFFFF),
            blurRadius: 18,
          ),
        ),
      ),
      // capsule with strong dispersion
      Positioned(
        left: 1040,
        top: 160,
        child: LiquidGlassContainer(
          width: 260,
          height: 110,
          settings: LiquidGlassSettings(
            shape: GlassShape.capsule(),
            thickness: 30,
            dispersion: 20,
          ),
        ),
      ),
    ]);
  });

  testWidgets('refraction screenshot', skip: !enabled, (tester) async {
    await _shoot(
      tester,
      'refraction.png',
      'assets/bg-buildings.png',
      1154 / 816,
      const [
        // crisp refraction + dispersion over structured detail
        Positioned(
          left: 300,
          top: 240,
          child: LiquidGlassContainer(
            width: 420,
            height: 300,
            settings: LiquidGlassSettings(
              thickness: 28,
              dispersion: 14,
              blurRadius: 0,
            ),
          ),
        ),
        // backdrop-blurred pane
        Positioned(
          left: 830,
          top: 330,
          child: LiquidGlassContainer(
            width: 340,
            height: 240,
            settings: LiquidGlassSettings(
              blurRadius: 28,
              tint: Color(0x22FFFFFF),
            ),
          ),
        ),
      ],
    );
  });
}
