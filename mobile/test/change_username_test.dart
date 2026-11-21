import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/controllers/auth_state.dart';
import 'package:mobile/core/username.dart';
import 'package:mobile/models/user.dart';
import 'package:mobile/pages/settings/accounts.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/themes/theme_provider.dart';
import 'package:provider/provider.dart';

import 'chat_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(mockPlatformChannels);

  group('the rules', () {
    test('are the same as when signing up', () {
      expect(usernamePrefixProblem('maya'), isNull);
      expect(usernamePrefixProblem('  Maya99 '), isNull);
      expect(usernamePrefixProblem('abc'), isNull);
      expect(usernamePrefixProblem('a' * 25), isNull);
      expect(usernamePrefixProblem('ab'), isNotNull);
      expect(usernamePrefixProblem('a' * 26), isNotNull);
      expect(usernamePrefixProblem(''), isNotNull);
      expect(usernamePrefixProblem('maya smith'), isNotNull);
      expect(usernamePrefixProblem('maya.smith'), isNotNull);
      expect(usernamePrefixProblem('maya_1'), isNotNull);
      expect(usernamePrefixProblem('mayá'), isNotNull);
    });

    test('the part before the dot is the one a person chooses', () {
      expect(usernamePrefix('alex.4821'), 'alex');
      expect(usernamePrefix('alex'), 'alex');
      expect(usernamePrefix('.1234'), '.1234');
    });

    test('a change is allowed once every 30 days', () {
      final now = DateTime(2026, 11, 21);
      expect(nextUsernameChange(null, now), isNull);
      expect(
        nextUsernameChange(now.subtract(const Duration(days: 29)), now),
        now.add(const Duration(days: 1)),
      );
      expect(
        nextUsernameChange(now.subtract(const Duration(days: 30)), now),
        isNull,
      );
      expect(
        nextUsernameChange(now.subtract(const Duration(days: 90)), now),
        isNull,
      );
    });
  });

  test('the profile says when the username was last changed', () {
    final user = UserModel.fromJson({
      'id': 'u1',
      'username': 'maya.1234',
      'display_name': 'Maya',
      'username_changed_at': '2026-11-01T10:00:00Z',
    });
    expect(user.usernameChangedAt, isNotNull);
    expect(user.usernameChangedAt!.toUtc().day, 1);
    expect(
      UserModel.fromJson({'id': 'u1', 'username': 'a.1234'}).usernameChangedAt,
      isNull,
    );
  });

  test(
    'a username that breaks the rules is refused before asking the server',
    () async {
      final auth = AuthState();
      expect(await auth.changeUsername('ab'), contains('letters and numbers'));
      expect(await auth.changeUsername('maya smith'), contains('only letters'));
    },
  );

  group('the dialog', () {
    Future<String?> open(WidgetTester tester) async {
      String? result = 'not closed';
      await tester.pumpWidget(
        MultiProvider(
          providers: [ChangeNotifierProvider(create: (_) => ThemeProvider())],
          child: MaterialApp(
            theme: AppThemes.getTheme(ThemeType.frost),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async => result = await showDialog<String>(
                    context: context,
                    builder: (_) =>
                        const ChangeUsernameDialog(current: 'maya.1234'),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return result;
    }

    FilledButton change(WidgetTester tester) => tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Change'),
    );

    testWidgets('says what changing it means', (tester) async {
      await open(tester);
      expect(
        find.textContaining('You will sign in with your new username'),
        findsOneWidget,
      );
      expect(find.textContaining('the old one stops working'), findsOneWidget);
      expect(find.textContaining('30 days'), findsOneWidget);
      expect(
        find.text('.####'),
        findsOneWidget,
        reason: 'the number is added for you',
      );
    });

    testWidgets('starts with the current name, which is not a change', (
      tester,
    ) async {
      await open(tester);
      expect(find.text('maya'), findsOneWidget);
      expect(change(tester).onPressed, isNull);
      // No red message before they have typed anything.
      expect(find.text('That is already your username.'), findsNothing);

      await tester.enterText(find.byType(TextField), 'MAYA');
      await tester.pump();
      expect(find.text('That is already your username.'), findsOneWidget);
      expect(change(tester).onPressed, isNull);
    });

    testWidgets('only a valid new name can be sent', (tester) async {
      await open(tester);
      await tester.enterText(find.byType(TextField), 'ab');
      await tester.pump();
      expect(change(tester).onPressed, isNull);
      expect(find.textContaining('3 to 25'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'maya smith');
      await tester.pump();
      expect(change(tester).onPressed, isNull);

      await tester.enterText(find.byType(TextField), 'Maya.Chen');
      await tester.pump();
      expect(change(tester).onPressed, isNull, reason: 'a dot is not allowed');

      await tester.enterText(find.byType(TextField), '  MayaChen ');
      await tester.pump();
      expect(change(tester).onPressed, isNotNull);
    });

    testWidgets('returns the new name', (tester) async {
      String? result = 'not closed';
      await tester.pumpWidget(
        MaterialApp(
          theme: AppThemes.getTheme(ThemeType.frost),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => result = await showDialog<String>(
                  context: context,
                  builder: (_) =>
                      const ChangeUsernameDialog(current: 'maya.1234'),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '  MayaChen ');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Change'));
      await tester.pumpAndSettle();
      expect(result, 'MayaChen');
    });

    testWidgets('sends nothing if cancelled', (tester) async {
      String? result = 'not closed';
      await tester.pumpWidget(
        MaterialApp(
          theme: AppThemes.getTheme(ThemeType.frost),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => result = await showDialog<String>(
                  context: context,
                  builder: (_) =>
                      const ChangeUsernameDialog(current: 'maya.1234'),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(result, isNull);
    });
  });
}
