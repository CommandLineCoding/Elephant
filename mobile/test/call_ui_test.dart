import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/controllers/auth_state.dart';
import 'package:mobile/controllers/call/call_controller.dart';
import 'package:mobile/controllers/chat/active_chat_controller.dart';
import 'package:mobile/controllers/chat/chat_connection_controller.dart';
import 'package:mobile/controllers/chat/chat_search_controller.dart';
import 'package:mobile/controllers/chat/group_details_controller.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/pages/call/call_page.dart';
import 'package:mobile/pages/chat/chat_page.dart';
import 'package:mobile/providers/group_controller_provider.dart';
import 'package:mobile/services/blocked_users.dart';
import 'package:mobile/services/calls/call_log.dart';
import 'package:mobile/services/calls/call_media.dart';
import 'package:mobile/services/calls/call_wiring.dart';
import 'package:mobile/services/chat/chat_event_handler.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/themes/theme_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'call_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in [
      'com.llfbandit.app_links/messages',
      'com.llfbandit.app_links/events',
      'dev.fluttercommunity.plus/connectivity',
      'dev.fluttercommunity.plus/connectivity_status',
      'plugins.it_nomads.com/flutter_secure_storage',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (call) async {
        if (call.method == 'check') return 'wifi';
        return null;
      });
    }
  });

  tearDown(() {
    CallController.instance = null;
    BlockedUsers.instance.clear();
    CallLog.instance.clear();
  });

  Widget callScreen(CallController call) => MaterialApp(
    theme: AppThemes.getTheme(ThemeType.nebula),
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => Navigator.of(context).push(CallPage.route(call)),
          child: const Text('open'),
        ),
      ),
    ),
  );

  group('call screen', () {
    testWidgets('an incoming call can be accepted', (tester) async {
      final h = Harness();
      await tester.pumpWidget(callScreen(h.call));
      await tester.runAsync(h.incoming);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Name of bob'), findsOneWidget);
      expect(find.text('Incoming voice call'), findsOneWidget);
      expect(find.text('End-to-end encrypted'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Accept'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(h.call.phase, CallPhase.connecting);
      expect(find.text('Connecting…'), findsOneWidget);
      expect(find.bySemanticsLabel('Mute'), findsOneWidget);
      expect(find.bySemanticsLabel('End call'), findsOneWidget);

      h.call.hangUp();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
    });

    testWidgets('declining closes the screen', (tester) async {
      final h = Harness();
      await tester.pumpWidget(callScreen(h.call));
      await tester.runAsync(h.incoming);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('Decline'));
      await tester.pump();
      expect(find.text('Declined'), findsOneWidget);
      expect(h.lastOf('call_hangup')['reason'], 'declined');

      // "Declined" shows briefly, then the screen goes.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(CallPage), findsNothing);
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('in a call: timer, mute, speaker, hang up', (tester) async {
      final h = Harness();
      await tester.pumpWidget(callScreen(h.call));
      await tester.runAsync(() async {
        await h.incoming();
        await h.call.accept();
      });
      h.media.onState!(MediaState.connected);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('0:00'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Mute'));
      await tester.pump();
      expect(h.media.muted, isTrue);
      expect(find.bySemanticsLabel('Unmute'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Speaker'));
      await tester.pump();
      expect(find.bySemanticsLabel('Speaker on'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('End call'));
      await tester.pump();
      expect(find.text('Call ended'), findsOneWidget);
      expect(h.lastOf('call_hangup')['reason'], 'ended');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(CallPage), findsNothing);
    });

    testWidgets('a call that fails to start closes the screen', (tester) async {
      final h = Harness()..servers = null;
      await tester.pumpWidget(callScreen(h.call));
      await tester.runAsync(() => h.call.call('bob', 'Bob'));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(CallPage), findsNothing);
    });
  });

  group('in a chat', () {
    Future<void> showChat(WidgetTester tester, {bool isGroup = false}) async {
      final inbox = InboxController()..hasLoadedOnce = true;
      final chat = ActiveChatController();
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => ThemeProvider()),
            ChangeNotifierProvider(create: (_) => AuthState()),
            ChangeNotifierProvider.value(value: inbox),
            ChangeNotifierProvider.value(value: chat),
            ChangeNotifierProvider(create: (_) => GroupController()),
            ChangeNotifierProvider(create: (_) => ChatSearchController()),
            ChangeNotifierProvider(create: (_) => GroupDetailsController()),
            ChangeNotifierProvider(
              create: (_) => ChatConnectionController(
                eventHandler: ChatEventHandler(
                  inboxController: inbox,
                  activeChatController: chat,
                  currentUserIdProvider: () => 'me',
                ),
              ),
            ),
          ],
          child: MaterialApp(
            theme: AppThemes.getTheme(ThemeType.frost),
            home: ChatPage(
              chatUserId: 'u-bob',
              displayName: 'Bob',
              username: 'bob.1234',
              isGroup: isGroup,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('a direct chat has a call button', (tester) async {
      await showChat(tester);
      expect(find.byTooltip('Voice call'), findsOneWidget);
    });

    testWidgets('a group chat has no call button', (tester) async {
      await showChat(tester, isGroup: true);
      expect(find.byTooltip('Voice call'), findsNothing);
    });

    testWidgets("you can't call someone you blocked", (tester) async {
      BlockedUsers.instance.debugSetUsers([
        const BlockedUser(
          id: 'u-bob',
          username: 'bob.1234',
          displayName: 'Bob',
        ),
      ]);
      await showChat(tester);
      expect(find.byTooltip('Voice call'), findsNothing);
    });

    testWidgets('calling opens the call screen', (tester) async {
      final h = Harness();
      CallController.instance = h.call;
      await showChat(tester);
      await tester.tap(find.byTooltip('Voice call'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(CallPage), findsOneWidget);
      expect(find.text('Calling…'), findsOneWidget);
      expect(h.lastOf('call_offer')['receiver_id'], 'u-bob');
      h.call.hangUp();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(CallPage), findsNothing);
    });

    testWidgets('calls show in the chat', (tester) async {
      CallLog.instance.debugSet('u-bob', [
        CallLogEntry(
          id: 'c1',
          chatId: 'u-bob',
          outgoing: false,
          outcome: CallOutcome.missed,
          startedAt: DateTime.now().subtract(const Duration(minutes: 5)),
        ),
        CallLogEntry(
          id: 'c2',
          chatId: 'u-bob',
          outgoing: true,
          outcome: CallOutcome.answered,
          startedAt: DateTime.now().subtract(const Duration(minutes: 2)),
          duration: const Duration(seconds: 75),
        ),
      ]);
      await showChat(tester);
      expect(find.text('Missed voice call'), findsOneWidget);
      expect(find.text('Voice call · 1:15'), findsOneWidget);
    });
  });

  group('decrypting call setup', () {
    test('refuses anything sent in the clear', () async {
      expect(
        await decryptCallSignal('bob', '{"sdp":"v=0","type":"offer"}'),
        isNull,
      );
      expect(
        await decryptCallSignal(
          'bob',
          '{"type":0,"ciphertext":"{\\"sdp\\":1}"}',
        ),
        isNull,
      );
    });
  });
}
