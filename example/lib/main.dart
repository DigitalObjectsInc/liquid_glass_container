import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';

import 'package:liquid_glass_container/liquid_glass_container.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(title: 'Liquid Glass', home: DemoPage());
  }
}

enum DemoBackground {
  checkerboard('Checker', null),
  animated('Anim', null),
  tahoeLight('Tahoe', 'assets/bg-tahoe-light.webp'),
  tahoeDark('Tahoe dark', 'assets/bg-tahoe-dark.webp'),
  buildings('Buildings', 'assets/bg-buildings.png'),
  text('Text', 'assets/bg-text.jpg'),
  grid('Grid', 'assets/bg-grid.png');

  const DemoBackground(this.label, this.asset);
  final String label;
  final String? asset;
}

/// Which glass implementation the demo scope runs.
enum DemoImpl {
  auto('Auto'),
  full('Full'),
  fallback('Fallback');

  const DemoImpl(this.label);
  final String label;
}

class DemoPage extends StatefulWidget {
  const DemoPage({super.key});

  @override
  State<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<DemoPage>
    with SingleTickerProviderStateMixin {
  // react-spring default config used by the reference's mouse spring
  static const _spring = SpringDescription(
    mass: 1,
    stiffness: 170,
    damping: 26,
  );
  static const _springSizeFactor = 10.0; // reference "Animation morph" default

  final _GlassParams _p = _GlassParams();
  late final Ticker _ticker;
  DemoBackground _bg = DemoBackground.checkerboard;
  DemoImpl _impl = DemoImpl.auto;
  Size _area = Size.zero;
  Timer? _autoTimer;
  int _autoStep = 0;
  Offset? _pos; // spring position, logical px (null = centered, not yet moved)
  Offset _target = Offset.zero;
  Offset _velocity = Offset.zero; // logical px/s
  SpringSimulation? _simX, _simY;
  Duration _simStart = Duration.zero;
  Duration _now = Duration.zero;

  void _retarget(Offset target, Size area) {
    // clamp to the scope bounds (drags can report positions outside the window)
    final clamped = Offset(
      target.dx.clamp(0.0, area.width),
      target.dy.clamp(0.0, area.height),
    );
    // A stopped Ticker restarts its elapsed time at zero; _now/_simStart must
    // rejoin that timeline or t goes negative and the spring diverges.
    if (!_ticker.isActive) {
      _now = Duration.zero;
      _ticker.start();
    }
    final p = _pos ?? area.center(Offset.zero);
    _target = clamped;
    _simX = SpringSimulation(_spring, p.dx, clamped.dx, _velocity.dx);
    _simY = SpringSimulation(_spring, p.dy, clamped.dy, _velocity.dy);
    _simStart = _now;
  }

  void _tick(Duration elapsed) {
    _now = elapsed;
    final t = (elapsed - _simStart).inMicroseconds / 1e6;
    var pos = Offset(_simX!.x(t), _simY!.x(t));
    var velocity = Offset(_simX!.dx(t), _simY!.dx(t));
    // self-heal if the simulation ever produces a non-finite state
    if (!pos.isFinite || !velocity.isFinite) {
      pos = _target;
      velocity = Offset.zero;
    }
    setState(() {
      _pos = pos;
      _velocity = velocity;
    });
    if (_simX!.isDone(t) && _simY!.isDone(t)) {
      _ticker.stop();
      _velocity = Offset.zero;
    }
  }

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);

    // measurement harness: ?impl=full|fb, ?bg=anim, ?auto
    final q = Uri.base.queryParameters;
    _impl = switch (q['impl']) {
      'full' => DemoImpl.full,
      'fb' => DemoImpl.fallback,
      _ => DemoImpl.auto,
    };
    if (q['bg'] == 'anim') _bg = DemoBackground.animated;
    if (q.containsKey('auto')) {
      _autoTimer = Timer.periodic(const Duration(milliseconds: 700), (_) {
        if (_area == Size.zero) return;
        final k = _autoStep++;
        _retarget(
          Offset(
            _area.width * (0.5 + 0.38 * math.cos(k * 2.4)),
            _area.height * (0.5 + 0.38 * math.sin(k * 1.7)),
          ),
          _area,
        );
      });
    }
    if (kProfileMode) {
      SchedulerBinding.instance.addTimingsCallback(_reportTimings);
    }
  }

  static final List<FrameTiming> _timings = [];

  // Printed every 120 frames; on web --profile capture Chrome's stderr log.
  static void _reportTimings(List<FrameTiming> ts) {
    _timings.addAll(ts);
    if (_timings.length < 120) return;
    double bSum = 0, rSum = 0, bMax = 0, rMax = 0;
    for (final t in _timings) {
      final b = t.buildDuration.inMicroseconds / 1000.0;
      final r = t.rasterDuration.inMicroseconds / 1000.0;
      bSum += b;
      rSum += r;
      if (b > bMax) bMax = b;
      if (r > rMax) rMax = r;
    }
    final n = _timings.length;
    _timings.clear();
    // ignore: avoid_print
    print(
      '[glass] $n frames: build avg ${(bSum / n).toStringAsFixed(1)}ms '
      'max ${bMax.toStringAsFixed(1)}ms | raster avg '
      '${(rSum / n).toStringAsFixed(1)}ms max ${rMax.toStringAsFixed(1)}ms',
    );
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _ticker.dispose();
    if (kProfileMode) {
      SchedulerBinding.instance.removeTimingsCallback(_reportTimings);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    // reference App.tsx: shape stretched by |spring speed| (device px/ms)
    final speed = _velocity * dpr / 1000;
    final w = p.width + speed.dx.abs() * p.width * _springSizeFactor / 100;
    final h = p.height + speed.dy.abs() * p.height * _springSizeFactor / 100;

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final area = _area = constraints.biggest;
              final raw = _pos ?? area.center(Offset.zero);
              // spring overshoot stays on screen
              final pos = Offset(
                raw.dx.clamp(0.0, area.width),
                raw.dy.clamp(0.0, area.height),
              );
              return Listener(
                behavior: HitTestBehavior.opaque,
                onPointerHover: (e) => _retarget(e.localPosition, area),
                onPointerMove: (e) => _retarget(e.localPosition, area),
                onPointerDown: (e) => _retarget(e.localPosition, area),
                child: GlassBackdropScope(
                  fallbackOnCanvasKit: _impl == DemoImpl.auto,
                  forceFallback: _impl == DemoImpl.fallback,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (_bg.asset case final asset?)
                        Image.asset(asset, fit: BoxFit.cover)
                      else if (_bg == DemoBackground.animated)
                        const AnimatedCheckerboard()
                      else
                        CustomPaint(painter: CheckerboardPainter()),
                      Center(
                        child: Container(
                          color: Colors.purple,
                          width: 100,
                          height: 100,
                        ),
                      ),
                      // center container first so tests can address it as .first
                      for (final dir in const [
                        Offset.zero,
                        Offset(-240, 0),
                        Offset(240, 0),
                        Offset(0, -240),
                        Offset(0, 240),
                      ])
                        Positioned(
                          left: pos.dx + dir.dx - w / 2,
                          top: pos.dy + dir.dy - h / 2,
                          child: LiquidGlassContainer(
                            width: w,
                            height: h,
                            cornerRadius: p.cornerRadius,
                            roundness: p.roundness,
                            refThickness: p.refThickness,
                            refFactor: p.refFactor,
                            refDispersion: p.refDispersion,
                            refFresnelRange: p.refFresnelRange,
                            refFresnelHardness: p.refFresnelHardness,
                            refFresnelFactor: p.refFresnelFactor,
                            glareRange: p.glareRange,
                            glareHardness: p.glareHardness,
                            glareFactor: p.glareFactor,
                            glareConvergence: p.glareConvergence,
                            glareOppositeFactor: p.glareOppositeFactor,
                            glareAngle: p.glareAngle,
                            blurRadius: p.blurRadius,
                            blurEdge: p.blurEdge,
                            tint: p.tintBase.withValues(alpha: p.tintAlpha),
                            shadowExpand: p.shadowExpand,
                            shadowFactor: p.shadowFactor,
                            shadowPosition: Offset(p.shadowDx, p.shadowDy),
                            child: dir == Offset.zero
                                ? const Text(
                                    'liquid glass',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 18,
                                      fontWeight: FontWeight.w600,
                                      shadows: [
                                        Shadow(
                                          color: Colors.black38,
                                          blurRadius: 6,
                                        ),
                                      ],
                                    ),
                                  )
                                : null,
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
          // outside the scope so the glass doesn't refract it
          _panel(),
        ],
      ),
    );
  }

  static const _labelStyle = TextStyle(fontSize: 12);

  static const _tintSwatches = [
    Color(0xFFFFFFFF),
    Color(0xFF000000),
    Color(0xFFFF3B30),
    Color(0xFFFF9500),
    Color(0xFFFFCC00),
    Color(0xFF34C759),
    Color(0xFF007AFF),
    Color(0xFFAF52DE),
  ];

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.only(top: 10, bottom: 2),
    child: Text(
      title,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: Colors.black54,
        letterSpacing: 0.4,
      ),
    ),
  );

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> set, {
    int digits = 0,
    int? divisions,
  }) => Row(
    children: [
      SizedBox(width: 92, child: Text(label, style: _labelStyle)),
      Expanded(
        child: SizedBox(
          height: 26,
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: (v) => setState(() => set(v)),
          ),
        ),
      ),
      SizedBox(
        width: 38,
        child: Text(
          value.toStringAsFixed(digits),
          style: _labelStyle,
          textAlign: TextAlign.right,
        ),
      ),
    ],
  );

  Widget _check(String label, bool value, ValueChanged<bool> set) => Row(
    children: [
      Expanded(child: Text(label, style: _labelStyle)),
      Checkbox(
        value: value,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        onChanged: (v) => setState(() => set(v!)),
      ),
    ],
  );

  Widget _panel() {
    final p = _p;
    return Positioned(
      top: 12,
      right: 12,
      bottom: 12,
      width: 300,
      child: Material(
        color: Colors.white.withValues(alpha: 0.94),
        elevation: 6,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: SliderTheme(
          data: SliderThemeData(
            trackHeight: 2,
            overlayShape: SliderComponentShape.noOverlay,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
          ),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
            children: [
              _section('Background'),
              Wrap(
                spacing: 4,
                children: [
                  for (final bg in DemoBackground.values)
                    ChoiceChip(
                      label: Text(bg.label),
                      labelStyle: _labelStyle,
                      visualDensity: VisualDensity.compact,
                      selected: _bg == bg,
                      onSelected: (_) => setState(() => _bg = bg),
                    ),
                ],
              ),
              _section('Implementation'),
              Wrap(
                spacing: 4,
                children: [
                  for (final impl in DemoImpl.values)
                    ChoiceChip(
                      label: Text(impl.label),
                      labelStyle: _labelStyle,
                      visualDensity: VisualDensity.compact,
                      selected: _impl == impl,
                      onSelected: (_) => setState(() => _impl = impl),
                    ),
                ],
              ),
              _section('Size'),
              _slider('Width', p.width, 50, 400, (v) => p.width = v),
              _slider('Height', p.height, 50, 400, (v) => p.height = v),
              _section('Shape'),
              _slider(
                'Corner radius',
                p.cornerRadius,
                0,
                100,
                (v) => p.cornerRadius = v,
              ),
              _slider(
                'Roundness',
                p.roundness,
                2,
                7,
                (v) => p.roundness = v,
                digits: 1,
              ),
              _section('Refraction'),
              _slider(
                'Thickness',
                p.refThickness,
                0,
                100,
                (v) => p.refThickness = v,
              ),
              _slider(
                'Index',
                p.refFactor,
                1,
                2.5,
                (v) => p.refFactor = v,
                digits: 2,
              ),
              _slider(
                'Dispersion',
                p.refDispersion,
                0,
                50,
                (v) => p.refDispersion = v,
              ),
              _section('Fresnel'),
              _slider(
                'Range',
                p.refFresnelRange,
                0,
                100,
                (v) => p.refFresnelRange = v,
              ),
              _slider(
                'Hardness',
                p.refFresnelHardness,
                0,
                100,
                (v) => p.refFresnelHardness = v,
              ),
              _slider(
                'Factor',
                p.refFresnelFactor,
                0,
                100,
                (v) => p.refFresnelFactor = v,
              ),
              _section('Glare'),
              _slider('Range', p.glareRange, 0, 100, (v) => p.glareRange = v),
              _slider(
                'Hardness',
                p.glareHardness,
                0,
                100,
                (v) => p.glareHardness = v,
              ),
              _slider(
                'Factor',
                p.glareFactor,
                0,
                120,
                (v) => p.glareFactor = v,
              ),
              _slider(
                'Convergence',
                p.glareConvergence,
                0,
                100,
                (v) => p.glareConvergence = v,
              ),
              _slider(
                'Opposite',
                p.glareOppositeFactor,
                0,
                100,
                (v) => p.glareOppositeFactor = v,
              ),
              _slider(
                'Angle',
                p.glareAngle,
                -180,
                180,
                (v) => p.glareAngle = v,
              ),
              _section('Blur'),
              _slider(
                'Radius',
                p.blurRadius.toDouble(),
                1,
                200,
                (v) => p.blurRadius = v.round(),
                divisions: 199,
              ),
              _check('Blur edge', p.blurEdge, (v) => p.blurEdge = v),
              _section('Tint'),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Wrap(
                  spacing: 6,
                  children: [
                    for (final c in _tintSwatches)
                      GestureDetector(
                        onTap: () => setState(() => p.tintBase = c),
                        child: Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            color: c,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: p.tintBase == c
                                  ? Colors.blueAccent
                                  : Colors.black26,
                              width: p.tintBase == c ? 2 : 1,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              _slider(
                'Alpha',
                p.tintAlpha,
                0,
                1,
                (v) => p.tintAlpha = v,
                digits: 2,
              ),
              _section('Shadow'),
              _slider(
                'Expand',
                p.shadowExpand,
                0,
                100,
                (v) => p.shadowExpand = v,
              ),
              _slider(
                'Factor',
                p.shadowFactor,
                0,
                100,
                (v) => p.shadowFactor = v,
              ),
              _slider('Offset X', p.shadowDx, -100, 100, (v) => p.shadowDx = v),
              _slider('Offset Y', p.shadowDy, -100, 100, (v) => p.shadowDy = v),
            ],
          ),
        ),
      ),
    );
  }
}

/// Demo-tweakable copy of every [LiquidGlassContainer] parameter
/// (defaults match; tint is split into base color + alpha for the panel).
class _GlassParams {
  double width = 200, height = 200;
  double cornerRadius = 80, roundness = 5;
  double refThickness = 20, refFactor = 1.4, refDispersion = 7;
  double refFresnelRange = 30, refFresnelHardness = 20, refFresnelFactor = 20;
  double glareRange = 30, glareHardness = 20, glareFactor = 90;
  double glareConvergence = 50, glareOppositeFactor = 80, glareAngle = -45;
  int blurRadius = 1;
  bool blurEdge = true;
  Color tintBase = const Color(0xFFFFFFFF);
  double tintAlpha = 0;
  double shadowExpand = 25, shadowFactor = 15;
  double shadowDx = 0, shadowDy = -10;
}

/// Reference bgType 0: 20 logical-px checkerboard, white / 0.75 grey.
/// [phase] shifts the grid horizontally (animated-backdrop stress mode).
class CheckerboardPainter extends CustomPainter {
  CheckerboardPainter([this.phase = 0]);

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
  bool shouldRepaint(CheckerboardPainter oldDelegate) =>
      oldDelegate.phase != phase;
}

/// Checkerboard scrolling 40 logical px/s: forces a backdrop content change
/// every frame (worst case for the capture pipeline, no-op for the fallback).
class AnimatedCheckerboard extends StatefulWidget {
  const AnimatedCheckerboard({super.key});

  @override
  State<AnimatedCheckerboard> createState() => _AnimatedCheckerboardState();
}

class _AnimatedCheckerboardState extends State<AnimatedCheckerboard>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  double _t = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      setState(() => _t = elapsed.inMicroseconds / 1e6);
    })..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: CheckerboardPainter(_t * 40));
}
