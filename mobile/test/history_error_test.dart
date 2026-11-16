import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/controllers/auth_state.dart';
import 'package:mobile/controllers/chat/active_chat_controller.dart';
import 'package:mobile/controllers/chat/chat_connection_controller.dart';
import 'package:mobile/controllers/chat/chat_search_controller.dart';
import 'package:mobile/controllers/chat/group_details_controller.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/models/message.dart';
import 'package:mobile/pages/chat/chat_page.dart';
import 'package:mobile/providers/group_controller_provider.dart';
import 'package:mobile/services/chat/chat_event_handler.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/themes/theme_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Counts Try again taps instead of going to the network.
class _RetryCounter extends ActiveChatController {
  int retries = 0;

  @override
  Future<void> retryHistory() async => retries++;

  @override
  Future<void> openChat(String targetUid, {bool isGroup = false}) async {}

  @override
  Future<void> loadMoreMessages() async {}
}

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

  test('a failed load sets the error and stops loading', () async {
    // There is no server in tests, so the history request fails.
    final chat = ActiveChatController();
    await chat.openChat('22222222-2222-4222-8222-222222222222');
    expect(chat.historyError, "Couldn't load messages");
    expect(chat.isChatHistoryLoading, isFalse);

    chat.hasMoreMessages = false;
    await chat.retryHistory();
    expect(chat.hasMoreMessages, isTrue, reason: 'Try again resets paging');
    expect(chat.historyError, "Couldn't load messages");
  });

  Future<_RetryCounter> showChat(
    WidgetTester tester, {
    required List<Message> messages,
  }) async {
    final chat = _RetryCounter()
      ..currentChatUserId = 'u2'
      ..activeChat = messages
      ..historyError = "Couldn't load messages";
    final inbox = InboxController()..hasLoadedOnce = true;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
          ChangeNotifierProvider(create: (_) => AuthState()),
          ChangeNotifierProvider.value(value: inbox),
          ChangeNotifierProvider<ActiveChatController>.value(value: chat),
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
            chatUserId: 'u2',
            displayName: 'Bob',
            username: 'bob.1234',
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    return chat;
  }

  testWidgets('an empty chat that failed to load offers Try again', (
    tester,
  ) async {
    final chat = await showChat(tester, messages: []);
    expect(find.text("Couldn't load messages"), findsOneWidget);
    expect(find.text('Say hello'), findsNothing);

    await tester.tap(find.text('Try again'));
    expect(chat.retries, 1);
  });

  testWidgets('cached messages stay visible with the error above them', (
    tester,
  ) async {
    final chat = await showChat(
      tester,
      messages: [
        Message(
          id: '1',
          senderId: 'u2',
          receiverId: 'me',
          content: 'an older cached message',
          createdAt: DateTime.now(),
          isRead: true,
        ),
      ],
    );
    expect(find.textContaining('an older cached message'), findsOneWidget);
    expect(find.text("Couldn't load messages"), findsOneWidget);

    await tester.tap(find.text('Try again'));
    expect(chat.retries, 1);
  });
}
