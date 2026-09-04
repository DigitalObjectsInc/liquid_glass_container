import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

/// The glass pane's outline: a superellipse-cornered rounded rectangle
/// matching the shader's SDF.
@immutable
final class GlassShape {
  /// Corners of [cornerRadius] logical px, clamped to half the pane's short
  /// side.
  const GlassShape.superellipse({
    required double cornerRadius,
    this.roundness = 5,
  }) : _corner = cornerRadius,
       _relative = false;

  /// Corners sized relative to the pane: radius = [cornerFactor] (0..1) of
  /// half the pane's short side.
  const GlassShape.relative({double cornerFactor = 0.8, this.roundness = 5})
    : _corner = cornerFactor,
      _relative = true;

  /// Fully rounded short sides (stadium / pill).
  const GlassShape.capsule({this.roundness = 5})
    : _corner = 1,
      _relative = true;

  /// Circular corners at maximum radius — a circle when the pane is square.
  const GlassShape.circle() : _corner = 1, _relative = true, roundness = 2;

  /// Sharp corners.
  const GlassShape.rect() : _corner = 0, _relative = false, roundness = 2;

  const GlassShape._(this._corner, this._relative, this.roundness);

  final double _corner;
  final bool _relative;

  /// Superellipse corner exponent, 2 (circular) .. 7 (squircle).
  final double roundness;

  /// The fixed corner radius in logical px, or null for a relative shape.
  double? get cornerRadius => _relative ? null : _corner;

  /// The corner factor (fraction of half the pane's short side), or null for
  /// a fixed-radius shape.
  double? get cornerFactor => _relative ? _corner : null;

  /// Corner radius in logical px for a pane of [size].
  double resolveRadius(Size size) {
    final half = math.min(size.width, size.height) / 2;
    return clampDouble(_relative ? _corner * half : _corner, 0, half);
  }

  /// Interpolates radius and roundness. A relative and an absolute shape
  /// cannot be blended without a size, so mixed pairs snap at t = 0.5.
  static GlassShape? lerp(GlassShape? a, GlassShape? b, double t) {
    if (a == null || b == null || a._relative != b._relative) {
      return t < 0.5 ? a : b;
    }
    return GlassShape._(
      lerpDouble(a._corner, b._corner, t)!,
      a._relative,
      lerpDouble(a.roundness, b.roundness, t)!,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GlassShape &&
          other._corner == _corner &&
          other._relative == _relative &&
          other.roundness == roundness;

  @override
  int get hashCode => Object.hash(_corner, _relative, roundness);

  @override
  String toString() => _relative
      ? 'GlassShape.relative(cornerFactor: $_corner, roundness: $roundness)'
      : 'GlassShape.superellipse(cornerRadius: $_corner, '
            'roundness: $roundness)';
}

/// Visual settings for liquid glass panes.
///
/// Every field is nullable: null means "inherit". Resolution is field-wise —
/// package [defaults] ← `GlassBackdropScope.settings` ← the container's own
/// `settings` — so a pane can override a single knob:
///
/// ```dart
/// LiquidGlassContainer(
///   settings: LiquidGlassSettings(blurRadius: 40), // rest from the scope
/// )
/// ```
///
/// Values use Flutter conventions: logical px, 0..1 fractions, radians,
/// y-down offsets.
@immutable
final class LiquidGlassSettings {
  const LiquidGlassSettings({
    this.shape,
    this.thickness,
    this.indexOfRefraction,
    this.dispersion,
    this.fresnelRange,
    this.fresnelHardness,
    this.fresnelIntensity,
    this.glareRange,
    this.glareHardness,
    this.glareIntensity,
    this.glareConvergence,
    this.glareOppositeIntensity,
    this.glareAngle,
    this.blurRadius,
    this.blurEdge,
    this.tint,
    this.shadowBlur,
    this.shadowIntensity,
    this.shadowOffset,
  }) : assert(thickness == null || thickness >= 0),
       assert(indexOfRefraction == null || indexOfRefraction >= 1),
       assert(dispersion == null || dispersion >= 0),
       assert(blurRadius == null || blurRadius >= 0),
       assert(shadowBlur == null || shadowBlur >= 0);

  /// Package defaults (the reference's control-panel defaults); every field
  /// non-null. Unset fields resolve here after scope and container merging.
  static const LiquidGlassSettings defaults = LiquidGlassSettings(
    shape: GlassShape.relative(),
    thickness: 20,
    indexOfRefraction: 1.4,
    dispersion: 7,
    fresnelRange: 30,
    fresnelHardness: 0.2,
    fresnelIntensity: 0.2,
    glareRange: 30,
    glareHardness: 0.2,
    glareIntensity: 0.9,
    glareConvergence: 0.5,
    glareOppositeIntensity: 0.8,
    glareAngle: -math.pi / 4,
    blurRadius: 1,
    blurEdge: true,
    tint: Color(0x00FFFFFF),
    shadowBlur: 25,
    shadowIntensity: 0.15,
    shadowOffset: Offset(0, 10),
  );

  /// Pane outline. Default: superellipse, corner factor 0.8, roundness 5.
  final GlassShape? shape;

  /// Refraction band depth in logical px. Default 20.
  final double? thickness;

  /// Index of refraction, 1 (none) .. ~2.5. Default 1.4.
  final double? indexOfRefraction;

  /// Chromatic dispersion strength, 0..50. Default 7.
  final double? dispersion;

  /// Fresnel rim width, 0..100. Default 30.
  final double? fresnelRange;

  /// Fresnel rim edge hardness, 0..1. Default 0.2.
  final double? fresnelHardness;

  /// Fresnel rim strength, 0..1. Default 0.2.
  final double? fresnelIntensity;

  /// Glare band width, 0..100. Default 30.
  final double? glareRange;

  /// Glare edge hardness, 0..1. Default 0.2.
  final double? glareHardness;

  /// Glare strength, 0..1.2. Default 0.9.
  final double? glareIntensity;

  /// How tightly glare converges toward the highlight axis, 0..1. Default 0.5.
  final double? glareConvergence;

  /// Strength of the secondary glare opposite the highlight, 0..1.
  /// Default 0.8.
  final double? glareOppositeIntensity;

  /// Glare highlight angle in radians. Default -π/4.
  final double? glareAngle;

  /// Backdrop blur radius in logical px, 0..100. Default 1: effectively off,
  /// because the blur pass runs only above 2 device px.
  final double? blurRadius;

  /// Whether the blur reaches into the refraction band. Default true.
  final bool? blurEdge;

  /// LCH-blended tint color. Default fully transparent.
  final Color? tint;

  /// Drop/interior shadow softness (gaussian blur sigma, logical px).
  /// Default 25.
  final double? shadowBlur;

  /// Shadow strength, 0..1. Default 0.15.
  final double? shadowIntensity;

  /// Shadow offset, y-down logical px. Default Offset(0, 10).
  final Offset? shadowOffset;

  /// True when every field is non-null (fully resolved, nothing left to
  /// inherit). [defaults] resolves any settings: `defaults.merge(s)`.
  bool get isResolved =>
      shape != null &&
      thickness != null &&
      indexOfRefraction != null &&
      dispersion != null &&
      fresnelRange != null &&
      fresnelHardness != null &&
      fresnelIntensity != null &&
      glareRange != null &&
      glareHardness != null &&
      glareIntensity != null &&
      glareConvergence != null &&
      glareOppositeIntensity != null &&
      glareAngle != null &&
      blurRadius != null &&
      blurEdge != null &&
      tint != null &&
      shadowBlur != null &&
      shadowIntensity != null &&
      shadowOffset != null;

  /// This with [other]'s non-null fields on top.
  LiquidGlassSettings merge(LiquidGlassSettings? other) {
    if (other == null) return this;
    return LiquidGlassSettings(
      shape: other.shape ?? shape,
      thickness: other.thickness ?? thickness,
      indexOfRefraction: other.indexOfRefraction ?? indexOfRefraction,
      dispersion: other.dispersion ?? dispersion,
      fresnelRange: other.fresnelRange ?? fresnelRange,
      fresnelHardness: other.fresnelHardness ?? fresnelHardness,
      fresnelIntensity: other.fresnelIntensity ?? fresnelIntensity,
      glareRange: other.glareRange ?? glareRange,
      glareHardness: other.glareHardness ?? glareHardness,
      glareIntensity: other.glareIntensity ?? glareIntensity,
      glareConvergence: other.glareConvergence ?? glareConvergence,
      glareOppositeIntensity:
          other.glareOppositeIntensity ?? glareOppositeIntensity,
      glareAngle: other.glareAngle ?? glareAngle,
      blurRadius: other.blurRadius ?? blurRadius,
      blurEdge: other.blurEdge ?? blurEdge,
      tint: other.tint ?? tint,
      shadowBlur: other.shadowBlur ?? shadowBlur,
      shadowIntensity: other.shadowIntensity ?? shadowIntensity,
      shadowOffset: other.shadowOffset ?? shadowOffset,
    );
  }

  LiquidGlassSettings copyWith({
    GlassShape? shape,
    double? thickness,
    double? indexOfRefraction,
    double? dispersion,
    double? fresnelRange,
    double? fresnelHardness,
    double? fresnelIntensity,
    double? glareRange,
    double? glareHardness,
    double? glareIntensity,
    double? glareConvergence,
    double? glareOppositeIntensity,
    double? glareAngle,
    double? blurRadius,
    bool? blurEdge,
    Color? tint,
    double? shadowBlur,
    double? shadowIntensity,
    Offset? shadowOffset,
  }) => merge(
    LiquidGlassSettings(
      shape: shape,
      thickness: thickness,
      indexOfRefraction: indexOfRefraction,
      dispersion: dispersion,
      fresnelRange: fresnelRange,
      fresnelHardness: fresnelHardness,
      fresnelIntensity: fresnelIntensity,
      glareRange: glareRange,
      glareHardness: glareHardness,
      glareIntensity: glareIntensity,
      glareConvergence: glareConvergence,
      glareOppositeIntensity: glareOppositeIntensity,
      glareAngle: glareAngle,
      blurRadius: blurRadius,
      blurEdge: blurEdge,
      tint: tint,
      shadowBlur: shadowBlur,
      shadowIntensity: shadowIntensity,
      shadowOffset: shadowOffset,
    ),
  );

  /// Field-wise interpolation. Fields null on one side snap at t = 0.5;
  /// resolve both ends (e.g. via [defaults].merge) for smooth animation.
  static LiquidGlassSettings? lerp(
    LiquidGlassSettings? a,
    LiquidGlassSettings? b,
    double t,
  ) {
    if (a == null || b == null) return t < 0.5 ? a : b;
    return LiquidGlassSettings(
      shape: GlassShape.lerp(a.shape, b.shape, t),
      thickness: _lerpD(a.thickness, b.thickness, t),
      indexOfRefraction: _lerpD(a.indexOfRefraction, b.indexOfRefraction, t),
      dispersion: _lerpD(a.dispersion, b.dispersion, t),
      fresnelRange: _lerpD(a.fresnelRange, b.fresnelRange, t),
      fresnelHardness: _lerpD(a.fresnelHardness, b.fresnelHardness, t),
      fresnelIntensity: _lerpD(a.fresnelIntensity, b.fresnelIntensity, t),
      glareRange: _lerpD(a.glareRange, b.glareRange, t),
      glareHardness: _lerpD(a.glareHardness, b.glareHardness, t),
      glareIntensity: _lerpD(a.glareIntensity, b.glareIntensity, t),
      glareConvergence: _lerpD(a.glareConvergence, b.glareConvergence, t),
      glareOppositeIntensity: _lerpD(
        a.glareOppositeIntensity,
        b.glareOppositeIntensity,
        t,
      ),
      glareAngle: _lerpD(a.glareAngle, b.glareAngle, t),
      blurRadius: _lerpD(a.blurRadius, b.blurRadius, t),
      blurEdge: t < 0.5 ? a.blurEdge : b.blurEdge,
      tint: Color.lerp(a.tint, b.tint, t),
      shadowBlur: _lerpD(a.shadowBlur, b.shadowBlur, t),
      shadowIntensity: _lerpD(a.shadowIntensity, b.shadowIntensity, t),
      shadowOffset: Offset.lerp(a.shadowOffset, b.shadowOffset, t),
    );
  }

  static double? _lerpD(double? a, double? b, double t) =>
      a == null || b == null ? (t < 0.5 ? a : b) : a + (b - a) * t;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LiquidGlassSettings &&
          other.shape == shape &&
          other.thickness == thickness &&
          other.indexOfRefraction == indexOfRefraction &&
          other.dispersion == dispersion &&
          other.fresnelRange == fresnelRange &&
          other.fresnelHardness == fresnelHardness &&
          other.fresnelIntensity == fresnelIntensity &&
          other.glareRange == glareRange &&
          other.glareHardness == glareHardness &&
          other.glareIntensity == glareIntensity &&
          other.glareConvergence == glareConvergence &&
          other.glareOppositeIntensity == glareOppositeIntensity &&
          other.glareAngle == glareAngle &&
          other.blurRadius == blurRadius &&
          other.blurEdge == blurEdge &&
          other.tint == tint &&
          other.shadowBlur == shadowBlur &&
          other.shadowIntensity == shadowIntensity &&
          other.shadowOffset == shadowOffset;

  @override
  int get hashCode => Object.hash(
    shape,
    thickness,
    indexOfRefraction,
    dispersion,
    fresnelRange,
    fresnelHardness,
    fresnelIntensity,
    glareRange,
    glareHardness,
    glareIntensity,
    glareConvergence,
    glareOppositeIntensity,
    glareAngle,
    blurRadius,
    blurEdge,
    tint,
    shadowBlur,
    shadowIntensity,
    shadowOffset,
  );

  @override
  String toString() {
    final fields = <String>[
      if (shape != null) 'shape: $shape',
      if (thickness != null) 'thickness: $thickness',
      if (indexOfRefraction != null) 'indexOfRefraction: $indexOfRefraction',
      if (dispersion != null) 'dispersion: $dispersion',
      if (fresnelRange != null) 'fresnelRange: $fresnelRange',
      if (fresnelHardness != null) 'fresnelHardness: $fresnelHardness',
      if (fresnelIntensity != null) 'fresnelIntensity: $fresnelIntensity',
      if (glareRange != null) 'glareRange: $glareRange',
      if (glareHardness != null) 'glareHardness: $glareHardness',
      if (glareIntensity != null) 'glareIntensity: $glareIntensity',
      if (glareConvergence != null) 'glareConvergence: $glareConvergence',
      if (glareOppositeIntensity != null)
        'glareOppositeIntensity: $glareOppositeIntensity',
      if (glareAngle != null) 'glareAngle: $glareAngle',
      if (blurRadius != null) 'blurRadius: $blurRadius',
      if (blurEdge != null) 'blurEdge: $blurEdge',
      if (tint != null) 'tint: $tint',
      if (shadowBlur != null) 'shadowBlur: $shadowBlur',
      if (shadowIntensity != null) 'shadowIntensity: $shadowIntensity',
      if (shadowOffset != null) 'shadowOffset: $shadowOffset',
    ];
    return 'LiquidGlassSettings(${fields.join(', ')})';
  }
}
