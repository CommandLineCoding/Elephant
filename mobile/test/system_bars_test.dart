import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/themes/app_themes.dart';

void main() {
  test('status and navigation bar icons contrast with each theme', () {
    for (final type in ThemeType.values) {
      final palette = AppThemes.paletteOf(type);
      final style = AppThemes.getTheme(type).appBarTheme.systemOverlayStyle;
      // Icons are drawn light on dark themes and dark on light ones.
      final icons = palette.isDark ? Brightness.light : Brightness.dark;

      expect(style, isNotNull, reason: type.name);
      expect(style!.statusBarIconBrightness, icons, reason: type.name);
      expect(style.systemNavigationBarIconBrightness, icons, reason: type.name);
      expect(style.statusBarColor, Colors.transparent, reason: type.name);
      expect(
        style.systemNavigationBarColor,
        palette.background,
        reason: type.name,
      );
    }
  });
}
