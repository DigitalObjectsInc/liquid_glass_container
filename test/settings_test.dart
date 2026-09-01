import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_container/liquid_glass_container.dart';

void main() {
  group('GlassShape', () {
    test('resolveRadius: absolute clamps to half the short side', () {
      const shape = GlassShape.superellipse(cornerRadius: 40);
      expect(shape.resolveRadius(const Size(200, 100)), 40);
      expect(shape.resolveRadius(const Size(200, 60)), 30); // clamped
    });

    test('resolveRadius: relative / capsule / circle / rect', () {
      expect(
        const GlassShape.relative(cornerFactor: 0.5)
            .resolveRadius(const Size(200, 100)),
        25,
      );
      expect(const GlassShape.capsule().resolveRadius(const Size(200, 100)), 50);
      expect(const GlassShape.circle().resolveRadius(const Size(80, 80)), 40);
      expect(const GlassShape.rect().resolveRadius(const Size(200, 100)), 0);
      expect(const GlassShape.circle().roundness, 2);
    });

    test('lerp interpolates same-kind shapes, snaps mixed kinds at 0.5', () {
      final a = GlassShape.lerp(
        const GlassShape.superellipse(cornerRadius: 10, roundness: 3),
        const GlassShape.superellipse(cornerRadius: 30, roundness: 5),
        0.5,
      )!;
      expect(a.resolveRadius(const Size(200, 200)), 20);
      expect(a.roundness, 4);

      const abs = GlassShape.superellipse(cornerRadius: 10);
      const rel = GlassShape.relative();
      expect(GlassShape.lerp(abs, rel, 0.4), abs);
      expect(GlassShape.lerp(abs, rel, 0.6), rel);
      expect(GlassShape.lerp(abs, null, 0.6), isNull);
    });

    test('equality and hashCode', () {
      const a = GlassShape.superellipse(cornerRadius: 10);
      const b = GlassShape.superellipse(cornerRadius: 10);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const GlassShape.relative(cornerFactor: 10)));
      expect(a, isNot(const GlassShape.superellipse(cornerRadius: 12)));
    });
  });

  group('LiquidGlassSettings', () {
    test('defaults has every field non-null', () {
      const d = LiquidGlassSettings.defaults;
      expect(d.shape, isNotNull);
      expect(d.thickness, isNotNull);
      expect(d.indexOfRefraction, isNotNull);
      expect(d.dispersion, isNotNull);
      expect(d.fresnelRange, isNotNull);
      expect(d.fresnelHardness, isNotNull);
      expect(d.fresnelIntensity, isNotNull);
      expect(d.glareRange, isNotNull);
      expect(d.glareHardness, isNotNull);
      expect(d.glareIntensity, isNotNull);
      expect(d.glareConvergence, isNotNull);
      expect(d.glareOppositeIntensity, isNotNull);
      expect(d.glareAngle, isNotNull);
      expect(d.blurRadius, isNotNull);
      expect(d.blurEdge, isNotNull);
      expect(d.tint, isNotNull);
      expect(d.shadowBlur, isNotNull);
      expect(d.shadowIntensity, isNotNull);
      expect(d.shadowOffset, isNotNull);
    });

    test('merge is field-wise: non-null wins, null inherits', () {
      const base = LiquidGlassSettings(thickness: 10, dispersion: 5);
      const over = LiquidGlassSettings(dispersion: 9, blurRadius: 20);
      final merged = base.merge(over);
      expect(merged.thickness, 10);
      expect(merged.dispersion, 9);
      expect(merged.blurRadius, 20);
      expect(merged.fresnelRange, isNull);
      expect(base.merge(null), base);
    });

    test('copyWith overrides only the given fields (null keeps)', () {
      const s = LiquidGlassSettings(thickness: 10, blurRadius: 5);
      final c = s.copyWith(blurRadius: 8);
      expect(c.thickness, 10);
      expect(c.blurRadius, 8);
      expect(c.tint, isNull);
    });

    test('lerp interpolates, snaps null-on-one-side fields at 0.5', () {
      const a = LiquidGlassSettings(
        thickness: 10,
        blurRadius: 0,
        glareAngle: 0,
        blurEdge: false,
        tint: Color(0x00000000),
      );
      const b = LiquidGlassSettings(
        thickness: 30,
        blurRadius: 10,
        glareAngle: math.pi,
        blurEdge: true,
        dispersion: 8,
        tint: Color(0xFF000000),
      );
      final mid = LiquidGlassSettings.lerp(a, b, 0.5)!;
      expect(mid.thickness, 20);
      expect(mid.blurRadius, 5);
      expect(mid.glareAngle, math.pi / 2);
      expect(mid.blurEdge, isTrue); // discrete: b side at t >= 0.5
      expect(mid.tint!.a, closeTo(0.5, 0.01));
      expect(LiquidGlassSettings.lerp(a, b, 0.4)!.dispersion, isNull);
      expect(LiquidGlassSettings.lerp(a, b, 0.6)!.dispersion, 8);
      expect(LiquidGlassSettings.lerp(a, null, 0.4), a);
      expect(LiquidGlassSettings.lerp(a, null, 0.6), isNull);
    });

    test('equality and hashCode', () {
      const a = LiquidGlassSettings(thickness: 10, blurRadius: 5);
      const b = LiquidGlassSettings(thickness: 10, blurRadius: 5);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const LiquidGlassSettings(thickness: 10)));
    });
  });
}
