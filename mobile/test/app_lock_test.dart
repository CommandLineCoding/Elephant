import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/pages/settings/privacy_security.dart';
import 'package:mobile/services/app_lock.dart';
import 'package:mobile/services/privacy_settings.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/themes/theme_provider.dart';
import 'package:mobile/widgets/app_lock_gate.dart';
import 'package:mobile/widgets/ui/components.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_harness.dart';

/// The settings screen asks the server for the privacy settings; here it has
/// nothing to say.
class QuietServer implements PrivacyApi {
  @override
  Future<Map<String, dynamic>> load() async => {};

  @override
  Future<Map<String, dynamic>> save(Map<String, dynamic> change) async =>
      change;
}

class FakeAuthenticator implements Authenticator {
  bool supported = true;
  bool pass = true;
  final List<String> asked = [];

  /// Runs while the prompt is open, like the phone taking the app off screen.
  VoidCallback? whileAsking;

  @override
  Future<bool> isSupported() async => supported;

  @override
  Future<bool> authenticate(String reason) async {
    asked.add(reason);
    whileAsking?.call();
    return pass;
  }
}

class Clock {
  DateTime now = DateTime(2026, 11, 21, 12);
  void pass(Duration d) => now = now.add(d);
}

({AppLock lock, FakeAuthenticator phone, Clock clock}) newLock() {
  final phone = FakeAuthenticator();
  final clock = Clock();
  return (
    lock: AppLock(authenticator: phone, clock: () => clock.now),
    phone: phone,
    clock: clock,
  );
}

Future<SharedPreferences> prefs() => SharedPreferences.getInstance();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(mockPlatformChannels);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the setting', () {
    test('is off until the person turns it on', () async {
      final t = newLock();
      await t.lock.load();
      expect(t.lock.enabled, isFalse);
      expect(t.lock.locked, isFalse);
      expect(t.lock.lockAfter, Duration.zero);
    });

    test('turns on only after the phone confirms it is its owner', () async {
      final t = newLock();
      await t.lock.load();

      t.phone.pass = false;
      expect(await t.lock.setEnabled(true), isNotNull);
      expect(t.lock.enabled, isFalse);

      t.phone.pass = true;
      expect(await t.lock.setEnabled(true), isNull);
      expect(t.lock.enabled, isTrue);
      expect(
        t.lock.locked,
        isFalse,
        reason: 'they just unlocked to turn it on',
      );
      expect((await prefs()).getBool('app_lock'), isTrue);
    });

    test('can not be turned on without a screen lock to ask with', () async {
      final t = newLock();
      t.phone.supported = false;
      final error = await t.lock.setEnabled(true);
      expect(error, contains('screen lock'));
      expect(t.lock.enabled, isFalse);
      expect(t.phone.asked, isEmpty);
    });

    test(
      'is not switched off by someone who can not unlock the phone',
      () async {
        final t = newLock();
        await t.lock.setEnabled(true);

        t.phone.pass = false;
        expect(await t.lock.setEnabled(false), isNotNull);
        expect(t.lock.enabled, isTrue);

        t.phone.pass = true;
        expect(await t.lock.setEnabled(false), isNull);
        expect(t.lock.enabled, isFalse);
        expect((await prefs()).getBool('app_lock'), isFalse);
      },
    );

    test('starts the app locked when it is on', () async {
      SharedPreferences.setMockInitialValues({
        'app_lock': true,
        'app_lock_after_seconds': 300,
      });
      final t = newLock();
      await t.lock.load();
      expect(t.lock.locked, isTrue);
      expect(t.lock.lockAfter, const Duration(minutes: 5));
    });

    test('remembers how long to wait', () async {
      final t = newLock();
      await t.lock.setLockAfter(const Duration(minutes: 30));
      expect((await prefs()).getInt('app_lock_after_seconds'), 1800);

      final again = newLock();
      await again.lock.load();
      expect(again.lock.lockAfter, const Duration(minutes: 30));
    });

    test('an unknown saved wait falls back to immediately', () async {
      SharedPreferences.setMockInitialValues({'app_lock_after_seconds': 7});
      final t = newLock();
      await t.lock.load();
      expect(t.lock.lockAfter, Duration.zero);
    });
  });

  group('locking when the app comes back', () {
    Future<({AppLock lock, FakeAuthenticator phone, Clock clock})> on(
      Duration after,
    ) async {
      final t = newLock();
      await t.lock.setEnabled(true);
      await t.lock.setLockAfter(after);
      return t;
    }

    test('after the chosen time, and not before', () async {
      final t = await on(const Duration(minutes: 5));

      t.lock.didLeave();
      t.clock.pass(const Duration(minutes: 4, seconds: 59));
      t.lock.didReturn();
      expect(t.lock.locked, isFalse);

      t.lock.didLeave();
      t.clock.pass(const Duration(minutes: 5));
      t.lock.didReturn();
      expect(t.lock.locked, isTrue);
    });

    test('immediately means every time the app is left', () async {
      final t = await on(Duration.zero);
      t.lock.didLeave();
      t.lock.didReturn();
      expect(t.lock.locked, isTrue);
    });

    test('never when it is off', () async {
      final t = newLock();
      t.lock.didLeave();
      t.clock.pass(const Duration(days: 2));
      t.lock.didReturn();
      expect(t.lock.locked, isFalse);
    });

    test('a return that was not preceded by leaving does nothing', () async {
      final t = await on(Duration.zero);
      t.lock.didReturn();
      expect(t.lock.locked, isFalse);
    });

    test('the phone\'s own prompt does not lock the app again', () async {
      final t = await on(Duration.zero);
      t.lock.didLeave();
      t.lock.didReturn();
      expect(t.lock.locked, isTrue);

      // Opening the prompt takes the app off screen for a moment.
      t.phone.whileAsking = () {
        t.lock.didLeave();
        t.lock.didReturn();
      };
      expect(await t.lock.unlock(), isTrue);
      expect(
        t.lock.locked,
        isFalse,
        reason: 'it would loop for ever otherwise',
      );

      t.lock.didReturn();
      expect(t.lock.locked, isFalse);
    });
  });

  group('unlocking', () {
    Future<({AppLock lock, FakeAuthenticator phone, Clock clock})>
    locked() async {
      final t = newLock();
      await t.lock.setEnabled(true);
      t.lock.didLeave();
      t.lock.didReturn();
      expect(t.lock.locked, isTrue);
      return t;
    }

    test('stays locked when the prompt is failed or cancelled', () async {
      final t = await locked();
      t.phone.pass = false;
      expect(await t.lock.unlock(), isFalse);
      expect(t.lock.locked, isTrue);
    });

    test('opens with the phone\'s say-so', () async {
      final t = await locked();
      expect(await t.lock.unlock(), isTrue);
      expect(t.lock.locked, isFalse);
    });

    test(
      'does not keep the owner out if the phone lost its screen lock',
      () async {
        final t = await locked();
        t.phone.supported = false;
        expect(await t.lock.unlock(), isTrue);
        expect(t.lock.locked, isFalse);
      },
    );
  });

  group('the lock screen', () {
    Future<({AppLock lock, FakeAuthenticator phone, Clock clock})> pump(
      WidgetTester tester, {
      bool startLocked = true,
    }) async {
      final t = newLock();
      await t.lock.setEnabled(true);
      // The person doesn't pass the prompt, so the app stays covered.
      t.phone.pass = false;
      if (startLocked) {
        t.lock.didLeave();
        t.lock.didReturn();
      }
      await tester.pumpWidget(
        MaterialApp(
          theme: AppThemes.getTheme(ThemeType.frost),
          home: AppLockGate(
            lock: t.lock,
            child: const Scaffold(body: Center(child: Text('private chats'))),
          ),
        ),
      );
      return t;
    }

    testWidgets('covers the app, and asks once on its own', (tester) async {
      final t = await pump(tester);
      await tester.pumpAndSettle();

      expect(find.text('Elephant is locked'), findsOneWidget);
      expect(t.phone.asked.where((r) => r == 'Unlock Elephant'), hasLength(1));

      // It does not ask again by itself, however many times it redraws.
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(t.phone.asked.where((r) => r == 'Unlock Elephant'), hasLength(1));
    });

    testWidgets('hides the app from touch and from screen readers', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final t = await pump(tester);
      await tester.pumpAndSettle();
      expect(t.lock.locked, isTrue);

      expect(find.text('Elephant is locked'), findsOneWidget);
      expect(
        tester.getSemantics(find.text('Elephant is locked')),
        matchesSemantics(label: 'Elephant is locked'),
      );
      // The chats are in the tree but excluded and not tappable.
      expect(find.text('private chats', skipOffstage: false), findsOneWidget);
      expect(find.bySemanticsLabel('private chats'), findsNothing);
      handle.dispose();
    });

    testWidgets('a wrong try shows a message and Unlock tries again', (
      tester,
    ) async {
      final t = newLock();
      await t.lock.setEnabled(true);
      t.phone.pass = false;
      t.lock.didLeave();
      t.lock.didReturn();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppThemes.getTheme(ThemeType.frost),
          home: AppLockGate(
            lock: t.lock,
            child: const Scaffold(body: Text('private chats')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('That didn\'t work. Try again.'), findsOneWidget);
      expect(t.phone.asked.where((r) => r == 'Unlock Elephant'), hasLength(1));

      t.phone.pass = true;
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      expect(find.text('Elephant is locked'), findsNothing);
      expect(find.text('private chats'), findsOneWidget);
    });

    testWidgets('leaving and returning to the app locks it', (tester) async {
      await pump(tester, startLocked: false);
      expect(find.text('Elephant is locked'), findsNothing);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Elephant is locked'), findsOneWidget);
    });

    testWidgets('the call screen stays usable, and leaving it shows the lock', (
      tester,
    ) async {
      final t = newLock();
      await t.lock.setEnabled(true);
      t.phone.pass = false;
      t.lock.didLeave();
      t.lock.didReturn();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppThemes.getTheme(ThemeType.frost),
          home: AppLockGate(
            lock: t.lock,
            child: const Scaffold(body: Text('a ringing call')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Elephant is locked'), findsOneWidget);

      t.lock.callScreenOpen.value = true;
      await tester.pump();
      expect(find.text('Elephant is locked'), findsNothing);
      expect(find.text('a ringing call'), findsOneWidget);

      t.lock.callScreenOpen.value = false;
      await tester.pump();
      expect(find.text('Elephant is locked'), findsOneWidget);
    });
  });

  group('in settings', () {
    testWidgets('the switch turns it on, and says why when it can not', (
      tester,
    ) async {
      final t = newLock();
      AppLock.instance = t.lock;
      addTearDown(() => AppLock.instance = AppLock());
      PrivacySettings.instance = PrivacySettings(api: QuietServer());
      addTearDown(() => PrivacySettings.instance = PrivacySettings());
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
      Finder appLockSwitch() => find.descendant(
        of: find.ancestor(
          of: find.text('App lock'),
          matching: find.byType(ElephantTile),
        ),
        matching: find.byType(Switch),
      );
      expect(find.text('Lock after'), findsNothing);

      t.phone.supported = false;
      await tester.tap(appLockSwitch());
      await tester.pumpAndSettle();
      expect(find.textContaining('Set a screen lock'), findsOneWidget);
      expect(t.lock.enabled, isFalse);
      await tester.pump(const Duration(seconds: 5));

      t.phone.supported = true;
      await tester.tap(appLockSwitch());
      await tester.pumpAndSettle();
      expect(t.lock.enabled, isTrue);
      expect(find.text('Lock after'), findsOneWidget);
      expect(find.text('Immediately'), findsOneWidget);

      await tester.tap(find.text('Lock after'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('After 5 minutes'));
      await tester.pumpAndSettle();
      expect(t.lock.lockAfter, const Duration(minutes: 5));
      expect(find.text('After 5 minutes'), findsOneWidget);
    });
  });
}
