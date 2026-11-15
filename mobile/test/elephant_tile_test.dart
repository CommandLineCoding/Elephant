import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/ui/components.dart';

void main() {
  Future<void> show(WidgetTester tester, Widget trailing, {double text = 1}) {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(390, 844) * 3;
    tester.platformDispatcher.textScaleFactorTestValue = text;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    return tester.pumpWidget(
      MaterialApp(
        theme: AppThemes.getTheme(ThemeType.frost),
        home: Scaffold(
          body: ElephantTile(
            icon: Icons.verified_user_outlined,
            title: 'Verify safety number',
            subtitle: 'Compare numbers to make sure no one is listening in.',
            trailing: trailing,
            onTap: () {},
          ),
        ),
      ),
    );
  }

  // The tile's right edge, minus its padding.
  double contentRight(WidgetTester tester) =>
      tester.getTopRight(find.byType(ElephantTile)).dx - Insets.lg;

  testWidgets('a trailing switch sits against the right edge', (tester) async {
    await show(tester, Switch(value: true, onChanged: (_) {}));
    expect(tester.getTopRight(find.byType(Switch)).dx, contentRight(tester));
  });

  testWidgets('a trailing tag sits against the right edge', (tester) async {
    await show(tester, const TagPill('Not verified'));
    expect(tester.getTopRight(find.byType(TagPill)).dx, contentRight(tester));
  });

  testWidgets('at 200% text a tag shrinks instead of overflowing', (
    tester,
  ) async {
    await show(tester, const TagPill('Not verified'), text: 2);
    expect(tester.takeException(), isNull);
    expect(tester.getTopRight(find.byType(TagPill)).dx, contentRight(tester));
    final tile = tester.getSize(find.byType(ElephantTile)).width;
    expect(
      tester.getSize(find.byType(TagPill)).width,
      lessThanOrEqualTo(tile * 0.4),
    );
  });
}
