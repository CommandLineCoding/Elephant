import 'package:flutter/material.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeProvider extends ChangeNotifier {
  ThemeType _currentTheme = ThemeType.frost;

  ThemeType get currentTheme => _currentTheme;
  ThemeData get themeData => AppThemes.getTheme(_currentTheme);
  ElephantPalette get palette => AppThemes.paletteOf(_currentTheme);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final savedThemeIndex = prefs.getInt('app_theme');
    if (savedThemeIndex != null &&
        savedThemeIndex >= 0 &&
        savedThemeIndex < ThemeType.values.length) {
      _currentTheme = ThemeType.values[savedThemeIndex];
    }
  }

  Future<void> setTheme(ThemeType themeType) async {
    if (_currentTheme == themeType) return;
    _currentTheme = themeType;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('app_theme', themeType.index);
  }
}
