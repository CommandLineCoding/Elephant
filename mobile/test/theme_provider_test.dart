import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/themes/theme_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void systemIs(WidgetTester tester, Brightness brightness) {
    tester.platformDispatcher.platformBrightnessTestValue = brightness;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  }

  testWidgets('follows the system until a theme is picked', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final themes = ThemeProvider();
    addTearDown(themes.dispose);
    await themes.load();
    var notified = 0;
    themes.addListener(() => notified++);

    systemIs(tester, Brightness.light);
    expect(themes.followsSystem, isTrue);
    expect(themes.currentTheme, ThemeType.frost);

    systemIs(tester, Brightness.dark);
    expect(themes.currentTheme, ThemeType.nebula);
    expect(
      notified,
      greaterThan(0),
      reason: 'the app must rebuild on a switch',
    );
  });

  testWidgets('a picked theme stays when the system changes', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final themes = ThemeProvider();
    addTearDown(themes.dispose);
    await themes.load();

    await themes.setTheme(ThemeType.aura);
    systemIs(tester, Brightness.dark);
    expect(themes.followsSystem, isFalse);
    expect(themes.currentTheme, ThemeType.aura);
    expect(
      (await SharedPreferences.getInstance()).getInt('app_theme'),
      ThemeType.aura.index,
    );

    await themes.followSystem();
    expect(themes.currentTheme, ThemeType.nebula);
    expect((await SharedPreferences.getInstance()).getInt('app_theme'), isNull);
  });

  testWidgets('a theme saved by an earlier version is kept', (tester) async {
    SharedPreferences.setMockInitialValues({'app_theme': ThemeType.onyx.index});
    final themes = ThemeProvider();
    addTearDown(themes.dispose);
    await themes.load();

    systemIs(tester, Brightness.light);
    expect(themes.followsSystem, isFalse);
    expect(themes.currentTheme, ThemeType.onyx);
  });
}
