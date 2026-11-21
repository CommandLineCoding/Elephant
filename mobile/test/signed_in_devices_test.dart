import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/models/signed_in_device.dart';
import 'package:mobile/pages/settings/signed_in_devices.dart';
import 'package:mobile/services/auth_service.dart';
import 'package:mobile/services/device_name.dart';
import 'package:mobile/services/signed_in_devices.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/themes/theme_provider.dart';
import 'package:provider/provider.dart';

import 'chat_harness.dart';

final noon = DateTime(2026, 11, 21, 12);

Map<String, dynamic> entry(
  String id,
  String name, {
  bool current = false,
  Duration ago = Duration.zero,
}) => {
  'id': id,
  'device_name': name,
  'started_at': noon.subtract(const Duration(days: 3)).toIso8601String(),
  'last_used_at': noon.subtract(ago).toIso8601String(),
  'current': current,
};

SignedInDevice device(
  String id,
  String name, {
  bool current = false,
  Duration ago = Duration.zero,
}) => SignedInDevice.fromJson(entry(id, name, current: current, ago: ago))!;

class FakeDevices implements SignedInDevicesApi {
  List<SignedInDevice> devices;
  final List<String> signedOut = [];
  int signedOutOthers = 0;
  Object? failList;
  Object? failSignOut;

  FakeDevices(this.devices);

  @override
  Future<List<SignedInDevice>> list() async {
    if (failList != null) throw failList!;
    return List.of(devices);
  }

  @override
  Future<void> signOut(String id) async {
    if (failSignOut != null) throw failSignOut!;
    signedOut.add(id);
    devices = devices.where((d) => d.id != id).toList();
  }

  @override
  Future<void> signOutOthers() async {
    if (failSignOut != null) throw failSignOut!;
    signedOutOthers++;
    devices = devices.where((d) => d.isCurrent).toList();
  }
}

Future<void> show(WidgetTester tester, FakeDevices api) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(800, 2000);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MultiProvider(
      providers: [ChangeNotifierProvider(create: (_) => ThemeProvider())],
      child: MaterialApp(
        theme: AppThemes.getTheme(ThemeType.frost),
        home: SignedInDevicesPage(api: api, now: () => noon),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

String fakeJwt(Map<String, dynamic> claims) {
  String part(Object o) => base64Url.encode(utf8.encode(jsonEncode(o)));
  return '${part({'alg': 'HS256'})}.${part(claims)}.sig';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(mockPlatformChannels);

  group('reading the server list', () {
    test('a device with every field', () {
      final d = device('s1', '  Pixel 8 ', current: true);
      expect(d.id, 's1');
      expect(d.name, 'Pixel 8');
      expect(d.title, 'Pixel 8');
      expect(d.isCurrent, isTrue);
    });

    test('a device with no name is "Unknown device"', () {
      expect(device('s1', '').title, 'Unknown device');
      final d = SignedInDevice.fromJson({
        'id': 's1',
        'started_at': noon.toIso8601String(),
        'last_used_at': noon.toIso8601String(),
      })!;
      expect(d.title, 'Unknown device');
      expect(d.isCurrent, isFalse);
    });

    test('an entry that is not usable is skipped', () {
      expect(SignedInDevice.fromJson('nope'), isNull);
      expect(SignedInDevice.fromJson({'id': ''}), isNull);
      expect(
        SignedInDevice.fromJson({
          'id': 's1',
          'started_at': 'yesterday',
          'last_used_at': noon.toIso8601String(),
        }),
        isNull,
      );
    });

    test('says how long ago a device was used', () {
      String at(Duration ago) => describeLastActive(noon.subtract(ago), noon);
      expect(at(Duration.zero), 'Active now');
      expect(at(const Duration(minutes: 19)), 'Active now');
      expect(at(const Duration(minutes: 45)), 'Active 45 min ago');
      expect(at(const Duration(hours: 1)), 'Active 1 hour ago');
      expect(at(const Duration(hours: 5)), 'Active 5 hours ago');
      expect(at(const Duration(days: 1, hours: 2)), 'Active yesterday');
      expect(at(const Duration(days: 4)), 'Active 4 days ago');
    });
  });

  group('this phone', () {
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('elephant/window'),
            null,
          );
    });

    test('reads the session from its access token', () async {
      final auth = AuthService();
      await auth.saveTokens(fakeJwt({'sub': 'u1', 'sid': 'sess-1'}), 'r');
      expect(auth.sessionId, 'sess-1');

      await auth.saveTokens(fakeJwt({'sub': 'u1'}), 'r');
      expect(auth.sessionId, isNull, reason: 'a token from before sessions');

      await auth.saveTokens('not-a-jwt', 'r');
      expect(auth.sessionId, isNull);

      await auth.logout();
      expect(auth.sessionId, isNull);
    });

    test(
      'has a name from the native side, and none if it can not say',
      () async {
        expect(await DeviceName.get(), '', reason: 'no native side in a test');

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('elephant/window'),
              (call) async =>
                  call.method == 'deviceName' ? ' Google Pixel 8 ' : null,
            );
        expect(await DeviceName.get(), 'Google Pixel 8');
      },
    );
  });

  group('the screen', () {
    testWidgets('lists this device and the others', (tester) async {
      await show(
        tester,
        FakeDevices([
          device('s1', 'Pixel 8', current: true),
          device('s2', 'Galaxy Tab S9', ago: const Duration(hours: 5)),
          device('s3', '', ago: const Duration(days: 4)),
        ]),
      );
      expect(find.text('Pixel 8'), findsOneWidget);
      expect(find.text('This device · Active now'), findsOneWidget);
      expect(find.text('Galaxy Tab S9'), findsOneWidget);
      expect(find.text('Active 5 hours ago'), findsOneWidget);
      expect(find.text('Unknown device'), findsOneWidget);
      expect(find.text('Active 4 days ago'), findsOneWidget);
      expect(find.text('Sign out all other devices'), findsOneWidget);
      // This device has no sign-out button of its own.
      expect(find.byTooltip('Sign out Pixel 8'), findsNothing);
      expect(find.byTooltip('Sign out Galaxy Tab S9'), findsOneWidget);
    });

    testWidgets('only this device', (tester) async {
      await show(tester, FakeDevices([device('s1', 'Pixel 8', current: true)]));
      expect(find.text('You\'re not signed in anywhere else.'), findsOneWidget);
      expect(find.text('Sign out all other devices'), findsNothing);
    });

    testWidgets('signs one device out after asking', (tester) async {
      final api = FakeDevices([
        device('s1', 'Pixel 8', current: true),
        device('s2', 'Galaxy Tab S9'),
      ]);
      await show(tester, api);

      await tester.tap(find.byTooltip('Sign out Galaxy Tab S9'));
      await tester.pumpAndSettle();
      expect(find.text('Sign out Galaxy Tab S9?'), findsOneWidget);
      expect(api.signedOut, isEmpty, reason: 'nothing before the answer');

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(api.signedOut, isEmpty);

      await tester.tap(find.byTooltip('Sign out Galaxy Tab S9'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
      await tester.pumpAndSettle();

      expect(api.signedOut, ['s2']);
      expect(find.text('Galaxy Tab S9'), findsNothing, reason: 'list reloads');
      expect(find.text('Galaxy Tab S9 was signed out'), findsOneWidget);
      expect(find.text('You\'re not signed in anywhere else.'), findsOneWidget);
    });

    testWidgets('signs out all the others after asking', (tester) async {
      final api = FakeDevices([
        device('s1', 'Pixel 8', current: true),
        device('s2', 'Galaxy Tab S9'),
        device('s3', 'Old phone'),
      ]);
      await show(tester, api);

      await tester.tap(find.text('Sign out all other devices'));
      await tester.pumpAndSettle();
      expect(api.signedOutOthers, 0);
      await tester.tap(find.widgetWithText(FilledButton, 'Sign out others'));
      await tester.pumpAndSettle();

      expect(api.signedOutOthers, 1);
      expect(find.text('Galaxy Tab S9'), findsNothing);
      expect(find.text('Old phone'), findsNothing);
      expect(find.text('Pixel 8'), findsOneWidget);
    });

    testWidgets('says so when signing out fails, and keeps the list', (
      tester,
    ) async {
      final api = FakeDevices([
        device('s1', 'Pixel 8', current: true),
        device('s2', 'Galaxy Tab S9'),
      ])..failSignOut = Exception('offline');
      await show(tester, api);

      await tester.tap(find.byTooltip('Sign out Galaxy Tab S9'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
      await tester.pumpAndSettle();

      expect(find.text('Galaxy Tab S9'), findsOneWidget);
      expect(find.textContaining('Couldn\'t sign out'), findsOneWidget);
    });

    testWidgets('can try again when the list will not load', (tester) async {
      final api = FakeDevices([device('s1', 'Pixel 8', current: true)])
        ..failList = Exception('offline');
      await show(tester, api);
      expect(find.text('Couldn\'t load your devices'), findsOneWidget);

      api.failList = null;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Pixel 8'), findsOneWidget);
    });
  });
}
