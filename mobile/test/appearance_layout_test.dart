import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/pages/settings/appearance.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/themes/theme_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('theme cards start just below their label', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(390, 844) * 3;
    // A status bar, as on a phone.
    tester.view.padding = const FakeViewPadding(top: 24 * 3);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => ThemeProvider(),
        child: MaterialApp(
          theme: AppThemes.getTheme(ThemeType.nebula),
          home: const AppearanceSettings(),
        ),
      ),
    );
    await tester.pump();

    final label = tester.getBottomLeft(find.text('Theme')).dy;
    final grid = tester.getTopLeft(find.byType(GridView)).dy;
    final firstCard = tester
        .getTopLeft(
          find
              .descendant(
                of: find.byType(GridView),
                matching: find.byType(GestureDetector),
              )
              .first,
        )
        .dy;
    // The grid sits right under the label, and its first card at the top of
    // the grid, not pushed down by the status bar and app bar.
    expect(grid - label, lessThan(Insets.lg));
    expect(firstCard - grid, lessThan(1));
  });
}
