import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/pages/settings/privacy_security.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/themes/theme_provider.dart';
import 'package:mobile/widgets/ui/components.dart';
import 'package:provider/provider.dart';
import 'package:mobile/services/screen_security.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_harness.dart';

/// What the phone was last told about capture, or null if never.
bool? lastSecure;
int calls = 0;

void listenToWindow({bool missing = false}) {
  lastSecure = null;
  calls = 0;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('elephant/window'), (
        call,
      ) async {
        if (missing) throw MissingPluginException();
        expect(call.method, 'secure');
        calls++;
        lastSecure = (call.arguments as Map)['on'] as bool;
        return null;
      });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(mockPlatformChannels);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ScreenSecurity.screenSecure.value = false;
    ScreenSecurity.incognitoKeyboard.value = false;
    listenToWindow();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('elephant/window'), null);
  });

  group('the two switches', () {
    test('are off until the person turns them on', () async {
      await ScreenSecurity.load();
      expect(ScreenSecurity.screenSecure.value, isFalse);
      expect(ScreenSecurity.incognitoKeyboard.value, isFalse);
      expect(lastSecure, isFalse);
    });

    test('screen security blocks capture and is remembered', () async {
      await ScreenSecurity.setScreenSecure(true);
      expect(lastSecure, isTrue);

      ScreenSecurity.screenSecure.value = false;
      lastSecure = null;
      await ScreenSecurity.load();
      expect(ScreenSecurity.screenSecure.value, isTrue);
      expect(lastSecure, isTrue);

      await ScreenSecurity.setScreenSecure(false);
      expect(lastSecure, isFalse);
    });

    test(
      'the incognito keyboard is remembered and needs no native call',
      () async {
        await ScreenSecurity.setIncognitoKeyboard(true);
        expect(calls, 0);

        ScreenSecurity.incognitoKeyboard.value = false;
        await ScreenSecurity.load();
        expect(ScreenSecurity.incognitoKeyboard.value, isTrue);
      },
    );

    test('keep working where there is no native side', () async {
      listenToWindow(missing: true);
      await ScreenSecurity.setScreenSecure(true);
      expect(ScreenSecurity.screenSecure.value, isTrue);
    });
  });

  group('in the app', () {
    testWidgets('the message box asks the keyboard not to learn', (
      tester,
    ) async {
      await showTestChat(tester, messages: [testMessage('m1', 'hello')]);
      bool learns() => tester
          .widget<TextField>(find.byType(TextField).last)
          .enableIMEPersonalizedLearning;

      expect(learns(), isTrue);

      ScreenSecurity.incognitoKeyboard.value = true;
      await tester.pump();
      expect(learns(), isFalse);

      ScreenSecurity.incognitoKeyboard.value = false;
      await tester.pump();
      expect(learns(), isTrue);
    });

    testWidgets('the Privacy screen has both switches', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 2400);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MultiProvider(
          providers: [ChangeNotifierProvider(create: (_) => ThemeProvider())],
          child: MaterialApp(
            theme: AppThemes.getTheme(ThemeType.frost),
            home: const PrivacySecuritySettingsPage(),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Incognito keyboard'), findsOneWidget);

      final screen = find.ancestor(
        of: find.text('Screen security'),
        matching: find.byType(ElephantTile),
      );
      await tester.tap(
        find.descendant(of: screen, matching: find.byType(Switch)),
      );
      await tester.pump();
      expect(ScreenSecurity.screenSecure.value, isTrue);
      expect(lastSecure, isTrue);
    });
  });
}
