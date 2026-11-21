import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/pages/settings/privacy_security.dart';
import 'package:mobile/services/privacy_settings.dart';
import 'package:mobile/services/ws_service.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/themes/theme_provider.dart';
import 'package:mobile/widgets/home_page_widgets.dart';
import 'package:mobile/widgets/ui/components.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_harness.dart';

class FakeServer implements PrivacyApi {
  Map<String, dynamic> settings = {
    'online_status': 'contacts',
    'read_receipts': true,
    'group_adds': 'everyone',
  };
  final List<Map<String, dynamic>> saved = [];
  Object? failLoad;
  Object? failSave;

  @override
  Future<Map<String, dynamic>> load() async {
    if (failLoad != null) throw failLoad!;
    return Map.of(settings);
  }

  @override
  Future<Map<String, dynamic>> save(Map<String, dynamic> change) async {
    if (failSave != null) throw failSave!;
    saved.add(change);
    settings = {...settings, ...change};
    return Map.of(settings);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(mockPlatformChannels);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the settings', () {
    test('start at what the server does when nobody has changed anything', () {
      final s = PrivacySettings(api: FakeServer());
      expect(s.onlineStatus, Audience.contacts);
      expect(s.readReceipts, isTrue);
      expect(s.groupAdds, Audience.everyone);
    });

    test('are read from the server', () async {
      final server = FakeServer()
        ..settings = {
          'online_status': 'nobody',
          'read_receipts': false,
          'group_adds': 'contacts',
        };
      final s = PrivacySettings(api: server);
      await s.refresh();
      expect(s.onlineStatus, Audience.nobody);
      expect(s.readReceipts, isFalse);
      expect(s.groupAdds, Audience.contacts);
    });

    test('keep what they have if the server can not be reached', () async {
      final server = FakeServer()..failLoad = Exception('offline');
      final s = PrivacySettings(api: server)..readReceipts = false;
      await s.refresh();
      expect(s.readReceipts, isFalse);
    });

    test('an answer the app does not understand changes nothing', () async {
      final server = FakeServer()
        ..settings = {'online_status': 'friends', 'group_adds': 7};
      final s = PrivacySettings(api: server)..onlineStatus = Audience.nobody;
      await s.refresh();
      expect(s.onlineStatus, Audience.nobody);
      expect(s.groupAdds, Audience.everyone);
    });

    test('change on screen at once and are saved, one at a time', () async {
      final server = FakeServer();
      final s = PrivacySettings(api: server);
      final seen = <Audience>[];
      s.addListener(() => seen.add(s.onlineStatus));

      final saving = s.setOnlineStatus(Audience.nobody);
      expect(
        s.onlineStatus,
        Audience.nobody,
        reason: 'before the server answers',
      );
      await saving;
      await s.setReadReceipts(false);
      await s.setGroupAdds(Audience.contacts);

      expect(server.saved, [
        {'online_status': 'nobody'},
        {'read_receipts': false},
        {'group_adds': 'contacts'},
      ]);
      expect(s.readReceipts, isFalse);
      expect(s.groupAdds, Audience.contacts);
      expect(seen, isNotEmpty);
    });

    test('go back if the server refuses, and the error is passed on', () async {
      final server = FakeServer()..failSave = Exception('offline');
      final s = PrivacySettings(api: server);
      await expectLater(s.setReadReceipts(false), throwsException);
      expect(s.readReceipts, isTrue);
      await expectLater(s.setOnlineStatus(Audience.nobody), throwsException);
      expect(s.onlineStatus, Audience.contacts);
      await expectLater(s.setGroupAdds(Audience.nobody), throwsException);
      expect(s.groupAdds, Audience.everyone);
    });

    test('keep read receipts on this phone so they apply at startup', () async {
      final s = PrivacySettings(api: FakeServer());
      await s.setReadReceipts(false);
      expect(
        (await SharedPreferences.getInstance()).getBool('read_receipts'),
        isFalse,
      );

      final later = PrivacySettings(api: FakeServer());
      expect(later.readReceipts, isTrue);
      await later.loadLocal();
      expect(later.readReceipts, isFalse);
    });

    test('are forgotten on sign-out', () async {
      final s = PrivacySettings(api: FakeServer());
      await s.setReadReceipts(false);
      await s.setOnlineStatus(Audience.nobody);
      s.reset();
      expect(s.readReceipts, isTrue);
      expect(s.onlineStatus, Audience.contacts);
      await Future<void>.delayed(Duration.zero);
      expect(
        (await SharedPreferences.getInstance()).getBool('read_receipts'),
        isNull,
      );
    });
  });

  group('read receipts on the wire', () {
    test('are sent while the switch is on', () {
      expect(
        WebSocketService.readReceiptFrame(receiverId: 'u2', enabled: true),
        {'type': 'read_receipt', 'receiver_id': 'u2', 'group_id': null},
      );
      expect(
        WebSocketService.readReceiptFrame(groupId: 'g1', enabled: true),
        containsPair('group_id', 'g1'),
      );
    });

    test('are not sent at all while it is off', () {
      expect(
        WebSocketService.readReceiptFrame(receiverId: 'u2', enabled: false),
        isNull,
      );
      expect(
        WebSocketService.readReceiptFrame(groupId: 'g1', enabled: false),
        isNull,
      );
    });
  });

  group('read ticks', () {
    Future<void> tick(WidgetTester tester, {bool read = true}) async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [ChangeNotifierProvider(create: (_) => ThemeProvider())],
          child: MaterialApp(
            theme: AppThemes.getTheme(ThemeType.frost),
            home: Scaffold(
              body: DeliveryTick(
                isPending: false,
                isRead: read,
                color: Colors.grey,
              ),
            ),
          ),
        ),
      );
    }

    setUp(() => PrivacySettings.instance = PrivacySettings(api: FakeServer()));
    tearDown(() => PrivacySettings.instance = PrivacySettings());

    testWidgets('show Read while read receipts are on', (tester) async {
      await tick(tester);
      expect(find.bySemanticsLabel('Read'), findsOneWidget);
    });

    testWidgets('show a read message as delivered while they are off', (
      tester,
    ) async {
      PrivacySettings.instance.readReceipts = false;
      await tick(tester);
      expect(find.bySemanticsLabel('Read'), findsNothing);
      expect(find.bySemanticsLabel('Delivered'), findsOneWidget);
    });

    testWidgets('follow the switch as it changes', (tester) async {
      await tick(tester);
      expect(find.bySemanticsLabel('Read'), findsOneWidget);
      PrivacySettings.instance.readReceipts = false;
      PrivacySettings.instance.notifyListeners();
      await tester.pump();
      expect(find.bySemanticsLabel('Delivered'), findsOneWidget);
    });

    testWidgets('a message that has not been read stays Sent', (tester) async {
      await tick(tester, read: false);
      expect(find.bySemanticsLabel('Sent'), findsOneWidget);
    });
  });

  group('the Privacy screen', () {
    testWidgets('shows the three settings and saves a change', (tester) async {
      final server = FakeServer();
      PrivacySettings.instance = PrivacySettings(api: server);
      addTearDown(() => PrivacySettings.instance = PrivacySettings());
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 3000);
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
      await tester.pumpAndSettle();

      expect(find.text('Online status'), findsOneWidget);
      expect(find.text('Read receipts'), findsOneWidget);
      expect(find.text('Who can add you to groups'), findsOneWidget);
      expect(
        find.text('Everyone'),
        findsOneWidget,
        reason: 'group adds subtitle',
      );

      await tester.tap(find.text('Who can add you to groups'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nobody'));
      await tester.pumpAndSettle();
      expect(server.saved, [
        {'group_adds': 'nobody'},
      ]);
      expect(find.text('Nobody'), findsOneWidget);

      final tile = find.ancestor(
        of: find.text('Read receipts'),
        matching: find.byType(ElephantTile),
      );
      await tester.tap(
        find.descendant(of: tile, matching: find.byType(Switch)),
      );
      await tester.pumpAndSettle();
      expect(server.saved.last, {'read_receipts': false});
    });

    testWidgets('says why when the server refuses a change', (tester) async {
      final server = FakeServer()..failSave = Exception('offline');
      PrivacySettings.instance = PrivacySettings(api: server);
      addTearDown(() => PrivacySettings.instance = PrivacySettings());
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 3000);
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
      await tester.pumpAndSettle();

      final tile = find.ancestor(
        of: find.text('Read receipts'),
        matching: find.byType(ElephantTile),
      );
      await tester.tap(
        find.descendant(of: tile, matching: find.byType(Switch)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Couldn\'t save'), findsOneWidget);
      expect(PrivacySettings.instance.readReceipts, isTrue);
    });
  });
}
