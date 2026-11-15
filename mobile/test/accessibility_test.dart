import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/controllers/auth_state.dart';
import 'package:mobile/controllers/chat/active_chat_controller.dart';
import 'package:mobile/controllers/chat/chat_connection_controller.dart';
import 'package:mobile/controllers/chat/chat_search_controller.dart';
import 'package:mobile/controllers/chat/group_details_controller.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/models/inbox_item.dart';
import 'package:mobile/models/message.dart';
import 'package:mobile/pages/auth/login_page.dart';
import 'package:mobile/pages/chat/chat_details_page.dart';
import 'package:mobile/pages/chat/chat_page.dart';
import 'package:mobile/pages/home/home_page.dart';
import 'package:mobile/pages/new%20chat/new_chat_page.dart';
import 'package:mobile/pages/settings/accounts.dart';
import 'package:mobile/pages/settings/appearance.dart';
import 'package:mobile/pages/settings/help_about.dart';
import 'package:mobile/pages/settings/notifications.dart';
import 'package:mobile/pages/settings/privacy_security.dart';
import 'package:mobile/providers/group_controller_provider.dart';
import 'package:mobile/services/chat/chat_event_handler.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/themes/theme_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Runs Flutter's Android accessibility guidelines on the main screens: tap
/// targets of at least 48x48 dp, a label on everything tappable, and enough
/// text contrast.
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

  // Lives for the whole app in production, so it must outlive each test's
  // widget tree here too (NewChatPage clears it when disposed).
  final search = ChatSearchController();

  Future<void> render(
    WidgetTester tester,
    ThemeType theme,
    Widget page, {
    void Function(ActiveChatController)? chat,
  }) async {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(390, 844) * 3;
    addTearDown(tester.view.reset);

    final now = DateTime.now();
    final inbox = InboxController()
      ..hasLoadedOnce = true
      ..inbox = [
        InboxItem(
          id: 'u2',
          title: 'Bob Builder',
          username: 'bob.1234',
          lastMessage: 'Can we fix it?',
          timestamp: now,
          isGroup: false,
          unreadCount: 2,
          lastMessageSender: 'u2',
        ),
        InboxItem(
          id: 'g1',
          title: 'Hiking crew',
          username: '',
          lastMessage: 'See you there',
          timestamp: now.subtract(const Duration(days: 1)),
          isGroup: true,
          lastMessageSender: 'u2',
        ),
      ];
    final active = ActiveChatController();
    chat?.call(active);
    final themeProvider = ThemeProvider();
    await themeProvider.setTheme(theme);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: themeProvider),
          ChangeNotifierProvider(create: (_) => AuthState()),
          ChangeNotifierProvider.value(value: inbox),
          ChangeNotifierProvider.value(value: active),
          ChangeNotifierProvider(create: (_) => GroupController()),
          ChangeNotifierProvider.value(value: search),
          ChangeNotifierProvider(create: (_) => GroupDetailsController()),
          ChangeNotifierProvider(
            create: (_) => ChatConnectionController(
              eventHandler: ChatEventHandler(
                inboxController: inbox,
                activeChatController: active,
                currentUserIdProvider: () => 'me-id',
              ),
            ),
          ),
        ],
        child: MaterialApp(theme: AppThemes.getTheme(theme), home: page),
      ),
    );
    await tester.pump(const Duration(seconds: 3));
  }

  final now = DateTime.now();
  final screens = <String, Widget>{
    'sign-in': const LoginPage(),
    'home': const HomePage(),
    'chat': ChatPage(
      chatUserId: 'u2',
      displayName: 'Bob Builder',
      username: 'bob.1234',
    ),
    'new chat': const NewChatPage(),
    'contact info': const ChatDetailsPage(
      isGroup: false,
      chatName: 'Bob Builder',
      chatId: 'u2',
      username: 'bob.1234',
    ),
    'account': const AccountsSettings(),
    'appearance': const AppearanceSettings(),
    'privacy': const PrivacySecuritySettingsPage(),
    'notifications': const NotificationsSettingsPage(),
    'help': const HelpAboutPage(),
  };

  void chatMessages(ActiveChatController c) {
    c
      ..currentChatUserId = 'u2'
      ..activeChat = [
        Message(
          id: '1',
          senderId: 'u2',
          receiverId: 'me-id',
          content: 'Hello there',
          createdAt: now.subtract(const Duration(minutes: 5)),
          isRead: true,
        ),
        Message(
          id: '2',
          senderId: 'me-id',
          receiverId: 'u2',
          content: 'Hi! Shipping it now.',
          createdAt: now,
          isRead: true,
        ),
      ];
  }

  for (final theme in ThemeType.values) {
    for (final entry in screens.entries) {
      final label = '${entry.key} (${theme.name})';
      testWidgets('tap targets are at least 48 dp: $label', (tester) async {
        final handle = tester.ensureSemantics();
        await render(tester, theme, entry.value, chat: chatMessages);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        handle.dispose();
      });
      testWidgets('everything tappable has a label: $label', (tester) async {
        final handle = tester.ensureSemantics();
        await render(tester, theme, entry.value, chat: chatMessages);
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        handle.dispose();
      });
      testWidgets('text has enough contrast: $label', (tester) async {
        final handle = tester.ensureSemantics();
        await render(tester, theme, entry.value, chat: chatMessages);
        await expectLater(tester, meetsGuideline(textContrastGuideline));
        handle.dispose();
      });
    }
  }

  // The largest system font size. Any overflow or other layout error fails.
  for (final entry in screens.entries) {
    testWidgets('fits at 200% text size: ${entry.key}', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await render(tester, ThemeType.nebula, entry.value, chat: chatMessages);
      expect(tester.takeException(), isNull);
    });
  }
}
