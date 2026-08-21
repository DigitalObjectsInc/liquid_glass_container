import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_container/liquid_glass_container.dart';
import 'package:liquid_glass_container_example/main.dart';

void main() {
  // Loads the shaders through the packages/liquid_glass_container/... asset
  // key — the path consumers of the published package resolve.
  testWidgets('demo renders glass via package shader assets', (tester) async {
    await tester.binding.setSurfaceSize(const Size(600, 600));
    tester.view.physicalSize = const Size(1200, 1200);
    tester.view.devicePixelRatio = 2.0;
    // must resolve without the lib/-path fallback
    await tester.runAsync(
      () => ui.FragmentProgram.fromAsset(
        'packages/liquid_glass_container/lib/shaders/glass_main.frag',
      ),
    );
    await tester.runAsync(LiquidGlassContainer.precache);
    await tester.pumpWidget(const MyApp());
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    final scope = tester.renderObject<RenderGlassScope>(
      find.byType(GlassBackdropScope),
    );
    expect(scope.hasBackdrop, isTrue);
    expect(scope.generation, greaterThan(0));
    expect(find.text('Liquid Glass'), findsOneWidget);
  });
}
