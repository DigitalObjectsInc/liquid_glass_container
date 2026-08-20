/// Liquid glass for Flutter: a single-pass fragment-shader port of
/// [liquid-glass-studio](https://github.com/iyinchao/liquid-glass-studio)
/// with refraction, dispersion, fresnel, glare, backdrop blur and shadow.
///
/// Wrap a subtree in [GlassBackdropScope], then place [LiquidGlassContainer]s
/// anywhere below it.
library;

export 'src/liquid_glass_container.dart'
    show
        GlassBackdropScope,
        LiquidGlassContainer,
        RenderGlassScope,
        RenderLiquidGlassContainer;
