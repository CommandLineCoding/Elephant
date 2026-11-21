import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/controllers/auth_state.dart';
import 'package:mobile/pages/settings/two_step_page.dart';
import 'package:mobile/services/two_factor.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/themes/theme_provider.dart';
import 'package:mobile/widgets/two_factor_step.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'chat_harness.dart';

class FakeTwoFactor implements TwoFactorApi {
  TwoFactorStatus current;
  final List<String> calls = [];
  final codes = [for (var i = 0; i < 10; i++) 'abcd-efg$i'];
  Object? failStatus;
  Object? failEnable;
  Object? failDisable;

  FakeTwoFactor({this.current = const TwoFactorStatus()});

  @override
  Future<TwoFactorStatus> status() async {
    if (failStatus != null) throw failStatus!;
    return current;
  }

  @override
  Future<TwoFactorSetup> start() async {
    calls.add('start');
    return const TwoFactorSetup(
      secret: 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ',
      uri:
          'otpauth://totp/Elephant:maya.1234?secret=GEZDGNBVGY3TQOJQ&issuer=Elephant',
    );
  }

  @override
  Future<List<String>> enable(String code) async {
    calls.add('enable $code');
    if (failEnable != null) throw failEnable!;
    current = const TwoFactorStatus(enabled: true, recoveryCodesLeft: 10);
    return codes;
  }

  @override
  Future<void> disable(String password, String code) async {
    calls.add('disable $password $code');
    if (failDisable != null) throw failDisable!;
    current = const TwoFactorStatus();
  }
}

Widget app(Widget home) => MultiProvider(
  providers: [ChangeNotifierProvider(create: (_) => ThemeProvider())],
  child: MaterialApp(theme: AppThemes.getTheme(ThemeType.frost), home: home),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(mockPlatformChannels);

  group('reading the server', () {
    test('the status', () {
      final on = TwoFactorStatus.fromJson({
        'enabled': true,
        'recovery_codes_left': 7,
      });
      expect((on.enabled, on.recoveryCodesLeft), (true, 7));
      final off = TwoFactorStatus.fromJson({});
      expect((off.enabled, off.recoveryCodesLeft), (false, 0));
    });

    test('the key is shown in groups of four', () {
      const setup = TwoFactorSetup(secret: 'ABCDEFGHIJ', uri: 'otpauth://x');
      expect(setup.spacedSecret, 'ABCD EFGH IJ');
    });
  });

  group('the code step of signing in', () {
    Future<List<String>> show(
      WidgetTester tester, {
      bool busy = false,
      String? error,
      List<String>? backs,
    }) async {
      final sent = <String>[];
      await tester.pumpWidget(
        app(
          Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: TwoFactorStep(
                busy: busy,
                error: error,
                onSubmit: sent.add,
                onCancel: () => backs?.add('back'),
              ),
            ),
          ),
        ),
      );
      return sent;
    }

    FilledButton verify(WidgetTester tester) =>
        tester.widget<FilledButton>(find.byType(FilledButton));

    testWidgets('asks for six digits and sends them', (tester) async {
      final sent = await show(tester);
      expect(find.textContaining('6-digit code'), findsOneWidget);
      expect(verify(tester).onPressed, isNull);

      await tester.enterText(find.byType(TextField), '12345');
      await tester.pump();
      expect(verify(tester).onPressed, isNull);

      await tester.enterText(find.byType(TextField), '123 456');
      await tester.pump();
      expect(verify(tester).onPressed, isNotNull);
      await tester.tap(find.byType(FilledButton));
      expect(sent, ['123 456']);
    });

    testWidgets('only lets digits in for an authenticator code', (
      tester,
    ) async {
      await show(tester);
      await tester.enterText(find.byType(TextField), 'ab12cd');
      await tester.pump();
      expect(find.text('12'), findsOneWidget);
    });

    testWidgets(
      'a recovery code is eight characters, with or without the dash',
      (tester) async {
        final sent = await show(tester);
        await tester.tap(find.text('Use a recovery code'));
        await tester.pump();
        expect(find.textContaining('recovery codes you saved'), findsOneWidget);

        await tester.enterText(find.byType(TextField), 'k3f9-p2m');
        await tester.pump();
        expect(verify(tester).onPressed, isNull);
        await tester.enterText(find.byType(TextField), 'k3f9-p2mx');
        await tester.pump();
        expect(verify(tester).onPressed, isNotNull);
        await tester.enterText(find.byType(TextField), 'k3f9p2mx');
        await tester.pump();
        await tester.tap(find.byType(FilledButton));
        expect(sent, ['k3f9p2mx']);

        await tester.tap(find.text('Use my authenticator app'));
        await tester.pump();
        expect(find.textContaining('6-digit code'), findsOneWidget);
        expect(verify(tester).onPressed, isNull, reason: 'the box was cleared');
      },
    );

    testWidgets('shows why a code failed, and can go back', (tester) async {
      final backs = <String>[];
      await show(tester, error: 'that code didn\'t work', backs: backs);
      expect(find.text('that code didn\'t work'), findsOneWidget);
      await tester.tap(find.text('Back'));
      expect(backs, ['back']);
    });

    testWidgets('can not be sent twice while it is working', (tester) async {
      final sent = await show(tester, busy: true);
      await tester.enterText(find.byType(TextField), '123456');
      await tester.pump();
      expect(verify(tester).onPressed, isNull);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      expect(sent, isEmpty);
    });
  });

  group('the settings page', () {
    Future<void> open(WidgetTester tester, FakeTwoFactor api) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 3200);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app(TwoStepSignInPage(api: api)));
      await tester.pumpAndSettle();
    }

    testWidgets('starts with a way to turn it on', (tester) async {
      await open(tester, FakeTwoFactor());
      expect(find.text('Turn on'), findsOneWidget);
      expect(find.textContaining('authenticator app'), findsWidgets);
    });

    testWidgets(
      'turning it on: scan, confirm with a code, save the recovery codes',
      (tester) async {
        String? copied;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              if (call.method == 'Clipboard.setData') {
                copied = (call.arguments as Map)['text'] as String;
              }
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, null),
        );

        final api = FakeTwoFactor();
        await open(tester, api);
        await tester.tap(find.text('Turn on'));
        await tester.pumpAndSettle();

        expect(api.calls, ['start']);
        expect(find.byType(QrImageView), findsOneWidget);
        expect(
          find.text('GEZD GNBV GY3T QOJQ GEZD GNBV GY3T QOJQ'),
          findsOneWidget,
        );
        // Not on until a code is confirmed.
        FilledButton turnOn() => tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Turn on'),
        );
        expect(turnOn().onPressed, isNull);

        await tester.tap(find.text('GEZD GNBV GY3T QOJQ GEZD GNBV GY3T QOJQ'));
        await tester.pump();
        expect(copied, 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ');

        await tester.enterText(find.byType(TextField), '123456');
        await tester.pump();
        await tester.tap(find.widgetWithText(FilledButton, 'Turn on'));
        await tester.pumpAndSettle();
        expect(api.calls.last, 'enable 123456');

        // The recovery codes, shown now.
        expect(find.text('Save your recovery codes'), findsOneWidget);
        for (final c in api.codes) {
          expect(find.text(c), findsOneWidget);
        }
        await tester.tap(find.text('Copy all'));
        await tester.pump();
        expect(copied, api.codes.join('\n'));

        await tester.tap(find.text('I\'ve saved them'));
        await tester.pumpAndSettle();
        expect(find.text('Two-step sign-in is on'), findsOneWidget);
        expect(find.text('10 recovery codes left'), findsOneWidget);
        expect(
          find.text(api.codes.first),
          findsNothing,
          reason: 'shown only once',
        );
      },
    );

    testWidgets('a wrong code says so and stays on the scan step', (
      tester,
    ) async {
      final api = FakeTwoFactor()
        ..failEnable = Exception('that code didn\'t work');
      await open(tester, api);
      await tester.tap(find.text('Turn on'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '000000');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Turn on'));
      await tester.pumpAndSettle();
      expect(find.byType(QrImageView), findsOneWidget);
      expect(find.textContaining('Something went wrong'), findsOneWidget);
      expect(find.text('Save your recovery codes'), findsNothing);
    });

    testWidgets('cancelling setup goes back without turning it on', (
      tester,
    ) async {
      final api = FakeTwoFactor();
      await open(tester, api);
      await tester.tap(find.text('Turn on'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(QrImageView), findsNothing);
      expect(api.current.enabled, isFalse);
    });

    testWidgets('when it is on, turning it off needs the password and a code', (
      tester,
    ) async {
      final api = FakeTwoFactor(
        current: const TwoFactorStatus(enabled: true, recoveryCodesLeft: 1),
      );
      await open(tester, api);
      expect(find.text('1 recovery code left'), findsOneWidget);

      await tester.tap(find.text('Turn off'));
      await tester.pumpAndSettle();
      FilledButton confirm() => tester.widget<FilledButton>(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(FilledButton),
        ),
      );
      expect(confirm().onPressed, isNull);
      await tester.enterText(
        find.widgetWithText(TextField, 'Password'),
        'hunter2hunter2',
      );
      await tester.pump();
      expect(confirm().onPressed, isNull, reason: 'a code is needed too');
      await tester.enterText(find.widgetWithText(TextField, 'Code'), '123456');
      await tester.pump();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(FilledButton),
        ),
      );
      await tester.pumpAndSettle();

      expect(api.calls, ['disable hunter2hunter2 123456']);
      expect(find.text('Turn on'), findsOneWidget);
      expect(
        find.text('Two-step sign-in is off'),
        findsOneWidget,
        reason: 'the snack',
      );
    });

    testWidgets('cancelling the turn-off changes nothing', (tester) async {
      final api = FakeTwoFactor(
        current: const TwoFactorStatus(enabled: true, recoveryCodesLeft: 5),
      );
      await open(tester, api);
      await tester.tap(find.text('Turn off'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(api.calls, isEmpty);
      expect(find.text('Two-step sign-in is on'), findsOneWidget);
    });

    testWidgets('a refused turn-off says why', (tester) async {
      final api = FakeTwoFactor(
        current: const TwoFactorStatus(enabled: true, recoveryCodesLeft: 5),
      )..failDisable = Exception('That password isn\'t right');
      await open(tester, api);
      await tester.tap(find.text('Turn off'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Password'),
        'nope',
      );
      await tester.enterText(find.widgetWithText(TextField, 'Code'), '123456');
      await tester.pump();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(FilledButton),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Two-step sign-in is on'), findsOneWidget);
      expect(find.textContaining('Something went wrong'), findsOneWidget);
    });

    testWidgets('can try again when it will not load', (tester) async {
      final api = FakeTwoFactor()..failStatus = Exception('offline');
      await open(tester, api);
      expect(find.text('Couldn\'t load this'), findsOneWidget);
      api.failStatus = null;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Turn on'), findsOneWidget);
    });
  });

  group('the sign-in', () {
    test('has no code step until the password was right', () {
      final auth = AuthState();
      expect(auth.twoFactorChallenge, isNull);
    });

    test('cancelling goes back to the password', () {
      final auth = AuthState()..twoFactorChallenge = 'abc';
      auth.cancelTwoFactor();
      expect(auth.twoFactorChallenge, isNull);
      expect(auth.errorMessage, isNull);
    });

    test('a code with no sign-in waiting does nothing', () async {
      expect(await AuthState().handleTwoFactor('123456'), isFalse);
    });
  });
}
