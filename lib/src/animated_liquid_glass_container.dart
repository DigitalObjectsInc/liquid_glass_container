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

  final double? width;
  final double? height;
  final EdgeInsetsGeometry padding;
  final AlignmentGeometry alignment;
  final Clip clipBehavior;
  final LiquidGlassSettings? settings;
  final Widget? child;

  @override
  AnimatedWidgetBaseState<AnimatedLiquidGlassContainer> createState() =>
      _AnimatedLiquidGlassContainerState();
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
