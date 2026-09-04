import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'liquid_glass_container.dart';
import 'settings.dart';

/// Implicitly animated [LiquidGlassContainer]. Animates size, padding,
/// alignment, and every [LiquidGlassSettings] field over [duration].
///
/// Settings fields null on both ends stay null (inherited from the scope);
/// a field null on only one end snaps at the animation midpoint. Set it on
/// both ends for a smooth transition.
class AnimatedLiquidGlassContainer extends ImplicitlyAnimatedWidget {
  const AnimatedLiquidGlassContainer({
    super.key,
    this.width,
    this.height,
    this.padding = EdgeInsets.zero,
    this.alignment = Alignment.center,
    this.clipBehavior = Clip.none,
    this.settings,
    this.child,
    required super.duration,
    super.curve,
    super.onEnd,
  });

  /// Fixed pane width in logical px; null sizes to [child] (or expands).
  final double? width;

  /// Fixed pane height in logical px; null sizes to [child] (or expands).
  final double? height;

  /// Space between the pane edge and [child].
  final EdgeInsetsGeometry padding;

  /// [child]'s placement within the padded pane.
  final AlignmentGeometry alignment;

  /// Clips [child] to the glass shape when not [Clip.none]. Not animated.
  final Clip clipBehavior;

  /// Per-pane overrides of the scope's settings (field-wise, null inherits).
  final LiquidGlassSettings? settings;

  /// The widget below this widget in the tree, painted on top of the glass.
  final Widget? child;

  @override
  AnimatedWidgetBaseState<AnimatedLiquidGlassContainer> createState() =>
      _AnimatedLiquidGlassContainerState();

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(DoubleProperty('width', width, defaultValue: null))
      ..add(DoubleProperty('height', height, defaultValue: null))
      ..add(DiagnosticsProperty<EdgeInsetsGeometry>('padding', padding))
      ..add(DiagnosticsProperty<AlignmentGeometry>('alignment', alignment))
      ..add(EnumProperty<Clip>('clipBehavior', clipBehavior))
      ..add(
        DiagnosticsProperty<LiquidGlassSettings>(
          'settings',
          settings,
          defaultValue: null,
        ),
      );
  }
}

class _AnimatedLiquidGlassContainerState
    extends AnimatedWidgetBaseState<AnimatedLiquidGlassContainer> {
  Tween<double>? _width;
  Tween<double>? _height;
  EdgeInsetsGeometryTween? _padding;
  AlignmentGeometryTween? _alignment;
  _SettingsTween? _settings;

  @override
  void forEachTween(TweenVisitor<dynamic> visitor) {
    _width =
        visitor(_width, widget.width, (v) => Tween<double>(begin: v as double))
            as Tween<double>?;
    _height =
        visitor(
              _height,
              widget.height,
              (v) => Tween<double>(begin: v as double),
            )
            as Tween<double>?;
    _padding =
        visitor(
              _padding,
              widget.padding,
              (v) => EdgeInsetsGeometryTween(begin: v as EdgeInsetsGeometry),
            )
            as EdgeInsetsGeometryTween?;
    _alignment =
        visitor(
              _alignment,
              widget.alignment,
              (v) => AlignmentGeometryTween(begin: v as AlignmentGeometry),
            )
            as AlignmentGeometryTween?;
    _settings =
        visitor(
              _settings,
              widget.settings,
              (v) => _SettingsTween(begin: v as LiquidGlassSettings),
            )
            as _SettingsTween?;
  }

  @override
  Widget build(BuildContext context) => LiquidGlassContainer(
    width: _width?.evaluate(animation),
    height: _height?.evaluate(animation),
    padding: _padding?.evaluate(animation) ?? EdgeInsets.zero,
    alignment: _alignment?.evaluate(animation) ?? Alignment.center,
    clipBehavior: widget.clipBehavior,
    settings: _settings?.evaluate(animation),
    child: widget.child,
  );
}

class _SettingsTween extends Tween<LiquidGlassSettings?> {
  _SettingsTween({super.begin});

  @override
  LiquidGlassSettings? lerp(double t) =>
      LiquidGlassSettings.lerp(begin, end, t);
}
