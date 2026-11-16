import 'package:flutter/material.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The app's theme: the one the user picked, or until they pick one, Frost or
/// Nebula to match the system's light or dark setting.
class ThemeProvider extends ChangeNotifier with WidgetsBindingObserver {
  static const lightDefault = ThemeType.frost;
  static const darkDefault = ThemeType.nebula;

  /// The theme the user picked, or null to follow the system.
  ThemeType? _chosen;

  ThemeProvider() {
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// True until the user picks a theme (or after they turn "Match system"
  /// back on).
  bool get followsSystem => _chosen == null;

  ThemeType get currentTheme {
    if (_chosen != null) return _chosen!;
    final brightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    return brightness == Brightness.dark ? darkDefault : lightDefault;
  }

  ThemeData get themeData => AppThemes.getTheme(currentTheme);
  ElephantPalette get palette => AppThemes.paletteOf(currentTheme);

  @override
  void didChangePlatformBrightness() {
    if (followsSystem) notifyListeners();
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final savedThemeIndex = prefs.getInt('app_theme');
    if (savedThemeIndex != null &&
        savedThemeIndex >= 0 &&
        savedThemeIndex < ThemeType.values.length) {
      _chosen = ThemeType.values[savedThemeIndex];
    }
  }

  /// Picks a theme and stops following the system.
  Future<void> setTheme(ThemeType themeType) async {
    if (_chosen == themeType) return;
    _chosen = themeType;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('app_theme', themeType.index);
  }

  /// Forgets the picked theme and follows the system again.
  Future<void> followSystem() async {
    if (_chosen == null) return;
    _chosen = null;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('app_theme');
  }
}
