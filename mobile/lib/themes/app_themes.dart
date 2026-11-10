import 'package:flutter/material.dart';

enum ThemeType { frost, aura, onyx, nebula }

/// Raw colors for one Elephant theme. Every screen reads these through
/// [ThemeData.colorScheme] and the [ElephantTokens] extension, never directly.
///
/// Each theme has one accent. It marks the primary action, your own messages,
/// unread counts and focus; everything else is neutral.
class ElephantPalette {
  final String name;
  final String tagline;
  final Brightness brightness;
  final Color background;
  final Color surface;
  final Color accent;
  final Color onAccent;
  final Color text;
  final Color muted;
  final Color outline;
  final Color incomingBubble;

  const ElephantPalette({
    required this.name,
    required this.tagline,
    required this.brightness,
    required this.background,
    required this.surface,
    required this.accent,
    required this.onAccent,
    required this.text,
    required this.muted,
    required this.outline,
    required this.incomingBubble,
  });

  bool get isDark => brightness == Brightness.dark;
}

/// Theme-specific colors that Material's [ColorScheme] can't express.
@immutable
class ElephantTokens extends ThemeExtension<ElephantTokens> {
  /// Fill of cards, sheets and other raised surfaces.
  final Color panelFill;

  /// One-pixel borders and dividers.
  final Color hairline;
  final Color onAccent;
  final Color incomingBubble;
  final Color incomingText;
  final Color readTick;
  final Color success;
  final Color warning;

  const ElephantTokens({
    required this.panelFill,
    required this.hairline,
    required this.onAccent,
    required this.incomingBubble,
    required this.incomingText,
    required this.readTick,
    required this.success,
    required this.warning,
  });

  @override
  ElephantTokens copyWith({Color? panelFill, Color? hairline}) {
    return ElephantTokens(
      panelFill: panelFill ?? this.panelFill,
      hairline: hairline ?? this.hairline,
      onAccent: onAccent,
      incomingBubble: incomingBubble,
      incomingText: incomingText,
      readTick: readTick,
      success: success,
      warning: warning,
    );
  }

  @override
  ElephantTokens lerp(ThemeExtension<ElephantTokens>? other, double t) {
    if (other is! ElephantTokens) return this;
    return ElephantTokens(
      panelFill: Color.lerp(panelFill, other.panelFill, t)!,
      hairline: Color.lerp(hairline, other.hairline, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      incomingBubble: Color.lerp(incomingBubble, other.incomingBubble, t)!,
      incomingText: Color.lerp(incomingText, other.incomingText, t)!,
      readTick: Color.lerp(readTick, other.readTick, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
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
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 22;
  static const double bubble = 18;
}

extension ElephantThemeX on BuildContext {
  ThemeData get theme => Theme.of(this);
  ColorScheme get colors => Theme.of(this).colorScheme;
  ElephantTokens get tokens => Theme.of(this).extension<ElephantTokens>()!;
  TextTheme get text => Theme.of(this).textTheme;
}

class AppThemes {
  /// Bundled in assets/fonts/Inter (SIL Open Font License).
  static const String fontFamily = 'Inter';

  static const ElephantPalette frostPalette = ElephantPalette(
    name: 'Frost',
    tagline: 'Light, cool and clear',
    brightness: Brightness.light,
    background: Color(0xFFF5F6F8),
    surface: Color(0xFFFFFFFF),
    accent: Color(0xFF2B59E8),
    onAccent: Color(0xFFFFFFFF),
    text: Color(0xFF111827),
    muted: Color(0xFF646C7B),
    outline: Color(0xFFE2E5EA),
    incomingBubble: Color(0xFFFFFFFF),
  );

  static const ElephantPalette auraPalette = ElephantPalette(
    name: 'Aura',
    tagline: 'Light and warm',
    brightness: Brightness.light,
    background: Color(0xFFFAF6F0),
    surface: Color(0xFFFFFFFF),
    accent: Color(0xFFC2491F),
    onAccent: Color(0xFFFFFFFF),
    text: Color(0xFF261A12),
    muted: Color(0xFF7A665A),
    outline: Color(0xFFEBE2D6),
    incomingBubble: Color(0xFFFFFFFF),
  );

  static const ElephantPalette onyxPalette = ElephantPalette(
    name: 'Onyx',
    tagline: 'Dark, black and white',
    brightness: Brightness.dark,
    background: Color(0xFF0B0B0C),
    surface: Color(0xFF151517),
    accent: Color(0xFFF2F2F3),
    onAccent: Color(0xFF0B0B0C),
    text: Color(0xFFF2F2F3),
    muted: Color(0xFF8A8A93),
    outline: Color(0xFF27272B),
    incomingBubble: Color(0xFF1C1C1F),
  );

  static const ElephantPalette nebulaPalette = ElephantPalette(
    name: 'Nebula',
    tagline: 'Dark with a blue accent',
    brightness: Brightness.dark,
    background: Color(0xFF0E1015),
    surface: Color(0xFF16181F),
    accent: Color(0xFF5260EC),
    onAccent: Color(0xFFFFFFFF),
    text: Color(0xFFECEEF3),
    muted: Color(0xFF8B91A1),
    outline: Color(0xFF262932),
    incomingBubble: Color(0xFF1D2029),
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
          secondary: p.accent,
          onSecondary: p.onAccent,
          tertiary: p.accent,
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
            p.text.withValues(alpha: 0.09),
            p.surface,
          ),
          error: p.isDark ? const Color(0xFFFF6B7A) : const Color(0xFFD92D3A),
        );

    final tokens = ElephantTokens(
      panelFill: p.surface,
      hairline: p.outline,
      onAccent: p.onAccent,
      incomingBubble: p.incomingBubble,
      incomingText: p.text,
      readTick: p.isDark ? const Color(0xFF7DD3FC) : const Color(0xFF0B7AC4),
      success: p.isDark ? const Color(0xFF4ADE80) : const Color(0xFF15803D),
      warning: p.isDark ? const Color(0xFFFBBF24) : const Color(0xFFB45309),
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: p.brightness,
      colorScheme: scheme,
      fontFamily: fontFamily,
    );

    TextStyle style(
      double size,
      FontWeight weight,
      double height, {
      double spacing = 0,
      Color? color,
    }) {
      return TextStyle(
        fontFamily: fontFamily,
        fontSize: size,
        fontWeight: weight,
        height: height,
        letterSpacing: spacing,
        color: color ?? p.text,
      );
    }

    // A deliberately small scale: two heading sizes, three body sizes and a
    // caption. Weights carry the hierarchy.
    final textTheme = base.textTheme.copyWith(
      displaySmall: style(34, FontWeight.w700, 1.15, spacing: -1),
      headlineMedium: style(28, FontWeight.w700, 1.2, spacing: -0.7),
      headlineSmall: style(22, FontWeight.w700, 1.25, spacing: -0.4),
      titleLarge: style(20, FontWeight.w600, 1.3, spacing: -0.3),
      titleMedium: style(16, FontWeight.w600, 1.35, spacing: -0.15),
      titleSmall: style(14, FontWeight.w600, 1.35, spacing: -0.05),
      bodyLarge: style(16, FontWeight.w400, 1.4, spacing: -0.1),
      bodyMedium: style(14, FontWeight.w400, 1.4),
      bodySmall: style(12.5, FontWeight.w400, 1.35, color: p.muted),
      labelLarge: style(14, FontWeight.w600, 1.3),
      labelMedium: style(12, FontWeight.w500, 1.3, color: p.muted),
      labelSmall: style(11, FontWeight.w500, 1.3, spacing: 0.1, color: p.muted),
    );

    final inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(Radii.md),
      borderSide: BorderSide(color: p.outline),
    );

    return base.copyWith(
      scaffoldBackgroundColor: p.background,
      canvasColor: p.background,
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      extensions: [tokens],
      splashFactory: InkRipple.splashFactory,
      dividerTheme: DividerThemeData(color: p.outline, thickness: 1, space: 1),
      appBarTheme: AppBarTheme(
        backgroundColor: p.background,
        surfaceTintColor: Colors.transparent,
        foregroundColor: p.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge,
        iconTheme: IconThemeData(color: p.text),
      ),
      iconTheme: IconThemeData(color: p.text),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.surface,
        hintStyle: TextStyle(color: p.muted.withValues(alpha: 0.85)),
        labelStyle: TextStyle(color: p.muted),
        floatingLabelStyle: TextStyle(
          color: p.accent,
          fontWeight: FontWeight.w600,
        ),
        helperStyle: textTheme.bodySmall,
        prefixIconColor: p.muted,
        suffixIconColor: p.muted,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 15,
        ),
        border: inputBorder,
        enabledBorder: inputBorder,
        focusedBorder: inputBorder.copyWith(
          borderSide: BorderSide(
            color: p.isDark && p.accent.computeLuminance() > 0.8
                ? p.muted
                : p.accent,
            width: 1.5,
          ),
        ),
        errorBorder: inputBorder.copyWith(
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: inputBorder.copyWith(
          borderSide: BorderSide(color: scheme.error, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: p.accent,
          foregroundColor: p.onAccent,
          minimumSize: const Size(64, 48),
          elevation: 0,
          textStyle: textTheme.labelLarge?.copyWith(fontSize: 15),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.md),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: p.text,
          minimumSize: const Size(64, 48),
          side: BorderSide(color: p.outline),
          textStyle: textTheme.labelLarge?.copyWith(fontSize: 15),
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
          textStyle: textTheme.labelLarge,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.sm),
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: p.muted,
        textColor: p.text,
        contentPadding: const EdgeInsets.symmetric(horizontal: Insets.lg),
        titleTextStyle: textTheme.bodyLarge?.copyWith(
          fontWeight: FontWeight.w500,
        ),
        subtitleTextStyle: textTheme.bodyMedium?.copyWith(color: p.muted),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.xl),
          side: BorderSide(color: p.outline),
        ),
        titleTextStyle: textTheme.titleLarge,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: p.muted,
          height: 1.45,
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: Colors.transparent,
        elevation: 0,
        modalElevation: 0,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: p.isDark ? const Color(0xFFECEEF3) : p.text,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: p.isDark ? const Color(0xFF111318) : Colors.white,
          fontWeight: FontWeight.w500,
        ),
        actionTextColor: p.isDark ? p.accent : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: p.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          side: BorderSide(color: p.outline),
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
        labelStyle: textTheme.labelLarge,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.xl),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: p.accent,
        linearTrackColor: p.accent.withValues(alpha: 0.12),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: p.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 64,
        indicatorColor: Colors.transparent,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => textTheme.labelMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: states.contains(WidgetState.selected) ? p.text : p.muted,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 24,
            color: states.contains(WidgetState.selected) ? p.text : p.muted,
          ),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: p.accent,
        foregroundColor: p.onAccent,
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 0,
        highlightElevation: 0,
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
