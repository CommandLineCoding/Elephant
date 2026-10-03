import 'package:flutter/material.dart';

enum ThemeType { frost, aura, onyx, nebula }

/// Raw colors for one Elephant theme. Every screen reads these through
/// [ThemeData.colorScheme] and the [GlassTokens] extension, never directly.
class ElephantPalette {
  final String name;
  final String tagline;
  final Brightness brightness;
  final Color background;
  final Color surface;
  final Color accent;
  final Color accentAlt;
  final Color onAccent;
  final Color text;
  final Color muted;
  final Color outline;
  final Color incomingBubble;
  final List<Color> ambient;

  const ElephantPalette({
    required this.name,
    required this.tagline,
    required this.brightness,
    required this.background,
    required this.surface,
    required this.accent,
    required this.accentAlt,
    required this.onAccent,
    required this.text,
    required this.muted,
    required this.outline,
    required this.incomingBubble,
    required this.ambient,
  });

  bool get isDark => brightness == Brightness.dark;
}

/// Theme-specific design tokens that Material's [ColorScheme] can't express:
/// the frosted-glass surfaces, gradient accents and ambient glow behind them.
@immutable
class GlassTokens extends ThemeExtension<GlassTokens> {
  final Color glassFill;
  final Color glassBorder;
  final Color glassStrongFill;
  final LinearGradient accentGradient;
  final Color onAccent;
  final Color incomingBubble;
  final Color incomingText;
  final Color readTick;
  final Color success;
  final Color warning;
  final List<Color> ambient;
  final double blur;

  const GlassTokens({
    required this.glassFill,
    required this.glassBorder,
    required this.glassStrongFill,
    required this.accentGradient,
    required this.onAccent,
    required this.incomingBubble,
    required this.incomingText,
    required this.readTick,
    required this.success,
    required this.warning,
    required this.ambient,
    this.blur = 18,
  });

  @override
  GlassTokens copyWith({double? blur}) {
    return GlassTokens(
      glassFill: glassFill,
      glassBorder: glassBorder,
      glassStrongFill: glassStrongFill,
      accentGradient: accentGradient,
      onAccent: onAccent,
      incomingBubble: incomingBubble,
      incomingText: incomingText,
      readTick: readTick,
      success: success,
      warning: warning,
      ambient: ambient,
      blur: blur ?? this.blur,
    );
  }

  @override
  GlassTokens lerp(ThemeExtension<GlassTokens>? other, double t) {
    if (other is! GlassTokens) return this;
    return GlassTokens(
      glassFill: Color.lerp(glassFill, other.glassFill, t)!,
      glassBorder: Color.lerp(glassBorder, other.glassBorder, t)!,
      glassStrongFill: Color.lerp(glassStrongFill, other.glassStrongFill, t)!,
      accentGradient: LinearGradient.lerp(
        accentGradient,
        other.accentGradient,
        t,
      )!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      incomingBubble: Color.lerp(incomingBubble, other.incomingBubble, t)!,
      incomingText: Color.lerp(incomingText, other.incomingText, t)!,
      readTick: Color.lerp(readTick, other.readTick, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      ambient: List.generate(
        ambient.length,
        (i) =>
            Color.lerp(ambient[i], other.ambient[i % other.ambient.length], t)!,
      ),
      blur: blur + (other.blur - blur) * t,
    );
  }
}

/// Spacing and corner radii shared by every screen.
class Insets {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;

  /// Horizontal page gutter.
  static const double page = 20;
}

class Radii {
  static const double sm = 10;
  static const double md = 16;
  static const double lg = 22;
  static const double xl = 28;
  static const double bubble = 20;
}

extension ElephantThemeX on BuildContext {
  ThemeData get theme => Theme.of(this);
  ColorScheme get colors => Theme.of(this).colorScheme;
  GlassTokens get glass => Theme.of(this).extension<GlassTokens>()!;
  TextTheme get text => Theme.of(this).textTheme;
}

class AppThemes {
  static const ElephantPalette frostPalette = ElephantPalette(
    name: 'Frost',
    tagline: 'Crisp, cool and bright',
    brightness: Brightness.light,
    background: Color(0xFFF2F5FB),
    surface: Color(0xFFFFFFFF),
    accent: Color(0xFF2F6BFF),
    accentAlt: Color(0xFF14B8D4),
    onAccent: Color(0xFFFFFFFF),
    text: Color(0xFF0F172A),
    muted: Color(0xFF64748B),
    outline: Color(0xFFDCE3EE),
    incomingBubble: Color(0xFFFFFFFF),
    ambient: [Color(0xFF7FA6FF), Color(0xFF6FE3F0), Color(0xFFC3B5FF)],
  );

  static const ElephantPalette auraPalette = ElephantPalette(
    name: 'Aura',
    tagline: 'Warm light, soft glow',
    brightness: Brightness.light,
    background: Color(0xFFFFF7F1),
    surface: Color(0xFFFFFFFF),
    accent: Color(0xFFEF6A45),
    accentAlt: Color(0xFFF6A93B),
    onAccent: Color(0xFFFFFFFF),
    text: Color(0xFF2A1A14),
    muted: Color(0xFF8C7166),
    outline: Color(0xFFF0DFD5),
    incomingBubble: Color(0xFFFFFFFF),
    ambient: [Color(0xFFFFB38A), Color(0xFFFFD27A), Color(0xFFF7A1B5)],
  );

  static const ElephantPalette onyxPalette = ElephantPalette(
    name: 'Onyx',
    tagline: 'Pure dark, quiet contrast',
    brightness: Brightness.dark,
    background: Color(0xFF0A0A0C),
    surface: Color(0xFF16161A),
    accent: Color(0xFFF2F2F4),
    accentAlt: Color(0xFFA9A9B2),
    onAccent: Color(0xFF0A0A0C),
    text: Color(0xFFF4F4F6),
    muted: Color(0xFF8E8E98),
    outline: Color(0xFF2A2A30),
    incomingBubble: Color(0xFF1E1E23),
    ambient: [Color(0xFF3A3A44), Color(0xFF26262E), Color(0xFF4A4A55)],
  );

  static const ElephantPalette nebulaPalette = ElephantPalette(
    name: 'Nebula',
    tagline: 'Deep space, vivid light',
    brightness: Brightness.dark,
    background: Color(0xFF0B0916),
    surface: Color(0xFF17132B),
    accent: Color(0xFF8B5CF6),
    accentAlt: Color(0xFFEC4899),
    onAccent: Color(0xFFFFFFFF),
    text: Color(0xFFEFEAFF),
    muted: Color(0xFFA49BC8),
    outline: Color(0xFF2C2547),
    incomingBubble: Color(0xFF1F1A38),
    ambient: [Color(0xFF6D3EF0), Color(0xFFD93A8C), Color(0xFF2E5BFF)],
  );

  static ElephantPalette paletteOf(ThemeType type) {
    switch (type) {
      case ThemeType.frost:
        return frostPalette;
      case ThemeType.aura:
        return auraPalette;
      case ThemeType.onyx:
        return onyxPalette;
      case ThemeType.nebula:
        return nebulaPalette;
    }
  }

  static final Map<ThemeType, ThemeData> _cache = {};

  static ThemeData getTheme(ThemeType type) =>
      _cache[type] ??= _build(paletteOf(type));

  static ThemeData _build(ElephantPalette p) {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: p.accent,
          brightness: p.brightness,
        ).copyWith(
          primary: p.accent,
          onPrimary: p.onAccent,
          secondary: p.accentAlt,
          onSecondary: p.onAccent,
          tertiary: p.accentAlt,
          surface: p.surface,
          onSurface: p.text,
          onSurfaceVariant: p.muted,
          outline: p.outline,
          outlineVariant: p.outline,
          surfaceContainerLowest: p.background,
          surfaceContainerLow: Color.alphaBlend(
            p.text.withValues(alpha: 0.02),
            p.surface,
          ),
          surfaceContainer: Color.alphaBlend(
            p.text.withValues(alpha: 0.04),
            p.surface,
          ),
          surfaceContainerHigh: Color.alphaBlend(
            p.text.withValues(alpha: 0.06),
            p.surface,
          ),
          surfaceContainerHighest: Color.alphaBlend(
            p.text.withValues(alpha: 0.08),
            p.surface,
          ),
          error: p.isDark ? const Color(0xFFFF6B7A) : const Color(0xFFD92D3A),
        );

    final glass = GlassTokens(
      glassFill: p.surface.withValues(alpha: p.isDark ? 0.58 : 0.68),
      glassStrongFill: p.surface.withValues(alpha: p.isDark ? 0.82 : 0.88),
      glassBorder: p.isDark
          ? Colors.white.withValues(alpha: 0.08)
          : Colors.white.withValues(alpha: 0.75),
      accentGradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [p.accent, p.accentAlt],
      ),
      onAccent: p.onAccent,
      incomingBubble: p.isDark
          ? p.incomingBubble.withValues(alpha: 0.86)
          : p.incomingBubble.withValues(alpha: 0.9),
      incomingText: p.text,
      readTick: p.isDark ? const Color(0xFF7DD3FC) : const Color(0xFF0EA5E9),
      success: p.isDark ? const Color(0xFF4ADE80) : const Color(0xFF16A34A),
      warning: p.isDark ? const Color(0xFFFBBF24) : const Color(0xFFD97706),
      ambient: p.ambient,
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: p.brightness,
      colorScheme: scheme,
    );

    final textTheme = base.textTheme
        .apply(bodyColor: p.text, displayColor: p.text)
        .copyWith(
          headlineMedium: base.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: -0.6,
            color: p.text,
          ),
          titleLarge: base.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -0.3,
            color: p.text,
          ),
          titleMedium: base.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: -0.1,
            color: p.text,
          ),
          labelLarge: base.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.1,
          ),
          labelSmall: base.textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            color: p.muted,
          ),
        );

    final inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(Radii.md),
      borderSide: BorderSide(color: p.outline.withValues(alpha: 0.0)),
    );

    return base.copyWith(
      scaffoldBackgroundColor: p.background,
      canvasColor: p.background,
      textTheme: textTheme,
      extensions: [glass],
      splashFactory: InkSparkle.splashFactory,
      dividerTheme: DividerThemeData(
        color: p.outline.withValues(alpha: p.isDark ? 0.7 : 1),
        thickness: 1,
        space: 1,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: p.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge?.copyWith(fontSize: 20),
        iconTheme: IconThemeData(color: p.text),
      ),
      iconTheme: IconThemeData(color: p.text),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHigh.withValues(
          alpha: p.isDark ? 0.7 : 0.9,
        ),
        hintStyle: TextStyle(color: p.muted.withValues(alpha: 0.8)),
        labelStyle: TextStyle(color: p.muted),
        floatingLabelStyle: TextStyle(
          color: p.accent,
          fontWeight: FontWeight.w600,
        ),
        prefixIconColor: p.muted,
        suffixIconColor: p.muted,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: inputBorder,
        enabledBorder: inputBorder,
        focusedBorder: inputBorder.copyWith(
          borderSide: BorderSide(color: p.accent, width: 1.6),
        ),
        errorBorder: inputBorder.copyWith(
          borderSide: BorderSide(color: scheme.error, width: 1.2),
        ),
        focusedErrorBorder: inputBorder.copyWith(
          borderSide: BorderSide(color: scheme.error, width: 1.6),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: p.accent,
          foregroundColor: p.onAccent,
          minimumSize: const Size(64, 50),
          textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.md),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: p.text,
          minimumSize: const Size(64, 50),
          side: BorderSide(color: p.outline),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.md),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: p.isDark && p.accent.computeLuminance() > 0.8
              ? p.text
              : p.accent,
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.sm),
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: p.muted,
        textColor: p.text,
        contentPadding: const EdgeInsets.symmetric(horizontal: Insets.lg),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        titleTextStyle: textTheme.bodyLarge?.copyWith(
          fontWeight: FontWeight.w600,
          color: p.text,
        ),
        subtitleTextStyle: textTheme.bodyMedium?.copyWith(color: p.muted),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.xl),
        ),
        titleTextStyle: textTheme.titleLarge,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: p.muted,
          height: 1.45,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: Colors.transparent,
        elevation: 0,
        modalElevation: 0,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: p.isDark
            ? const Color(0xFFF4F4F6)
            : const Color(0xFF14161C),
        contentTextStyle: TextStyle(
          color: p.isDark ? const Color(0xFF14161C) : Colors.white,
          fontWeight: FontWeight.w500,
        ),
        actionTextColor: p.isDark ? p.accent.withValues(alpha: 1) : p.accentAlt,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: p.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shadowColor: Colors.black.withValues(alpha: 0.2),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        textStyle: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? p.onAccent : p.muted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? p.accent
              : scheme.surfaceContainerHighest,
        ),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        selectedColor: p.accent.withValues(alpha: 0.16),
        side: BorderSide.none,
        labelStyle: TextStyle(color: p.text, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.xl),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: p.accent,
        linearTrackColor: p.accent.withValues(alpha: 0.12),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: p.accent,
        foregroundColor: p.onAccent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.lg),
        ),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
        },
      ),
    );
  }
}
