import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/controllers/auth_state.dart';
import 'package:mobile/controllers/chat/active_chat_controller.dart';
import 'package:mobile/controllers/chat/chat_connection_controller.dart';
import 'package:mobile/controllers/chat/chat_search_controller.dart';
import 'package:mobile/controllers/chat/group_details_controller.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/core/message_envelope.dart';
import 'package:mobile/models/inbox_item.dart';
import 'package:mobile/models/message.dart';
import 'package:mobile/pages/auth/login_page.dart';
import 'package:mobile/pages/chat/chat_page.dart';
import 'package:mobile/pages/home/home_page.dart';
import 'package:mobile/pages/chat/chat_details_page.dart';
import 'package:mobile/pages/new%20chat/new_chat_page.dart';
import 'package:mobile/pages/new%20chat/select_contact_page.dart';
import 'package:mobile/pages/settings/accounts.dart';
import 'package:mobile/pages/settings/appearance.dart';
import 'package:mobile/pages/settings/help_about.dart';
import 'package:mobile/pages/settings/privacy_security.dart';
import 'package:mobile/providers/group_controller_provider.dart';
import 'package:mobile/services/chat/chat_event_handler.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/themes/theme_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Renders the main screens in every theme at a regular and a small phone
/// size. Any exception, including RenderFlex overflows, fails the test.
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

  const sizes = {'regular': Size(390, 844), 'small': Size(320, 600)};

  Future<void> render(
    WidgetTester tester,
    ThemeType theme,
    Size size,
    Widget page,
  ) async {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = size * 3;
    addTearDown(tester.view.reset);

    final auth = AuthState();
    final inbox = InboxController()
      ..hasLoadedOnce = true
      ..inbox = [
        InboxItem(
          id: 'u2',
          title: 'Bob Builder With A Rather Long Display Name',
          username: 'bob.1234',
          lastMessage:
              'Can we fix it? Yes we can, and this preview is long enough to need truncating.',
          timestamp: DateTime.now(),
          isGroup: false,
          unreadCount: 3,
          lastMessageSender: 'u2',
        ),
        InboxItem(
          id: 'u3',
          title: 'Ada',
          username: 'ada.1815',
          lastMessage: 'See you!',
          timestamp: DateTime.now().subtract(const Duration(days: 3)),
          isGroup: false,
          lastMessageSender: 'me',
          lastMessageIsRead: true,
        ),
      ];
    final chat = ActiveChatController();
    final themeProvider = ThemeProvider();
    await themeProvider.setTheme(theme);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: themeProvider),
          ChangeNotifierProvider.value(value: auth),
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
                currentUserIdProvider: () => 'me-id',
              ),
            ),
          ),
        ],
        child: MaterialApp(theme: AppThemes.getTheme(theme), home: page),
      ),
    );
    await tester.pump(const Duration(seconds: 2));
  }

  for (final theme in ThemeType.values) {
    for (final entry in sizes.entries) {
      final label = '${theme.name}/${entry.key}';

      testWidgets('login renders: $label', (tester) async {
        await render(tester, theme, entry.value, const LoginPage());
        await tester.tap(find.text('Register'));
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('Create account'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('home renders: $label', (tester) async {
        await render(tester, theme, entry.value, const HomePage());
        expect(find.text('Chats'), findsWidgets);
        await tester.tap(find.text('Groups').last);
        await tester.pump(const Duration(milliseconds: 600));
        await tester.tap(find.text('You').last);
        await tester.pump(const Duration(milliseconds: 600));
        expect(tester.takeException(), isNull);
      });

      testWidgets('chat renders: $label', (tester) async {
        final now = DateTime.now();
        Message msg(
          String id,
          String sender,
          String text, {
          Duration ago = Duration.zero,
          String? reply,
          DateTime? edited,
        }) {
          return Message(
            id: id,
            senderId: sender,
            receiverId: 'u2',
            content: text,
            createdAt: now.subtract(ago),
            isRead: sender == 'me',
            replyToMessageId: reply,
            editedAt: edited,
            quotedMessage: reply == null
                ? null
                : QuotedMessage(
                    id: reply,
                    senderId: 'u2',
                    senderDisplayName: '',
                    content: 'Original **message**',
                  ),
          );
        }

        final page = ChatPage(
          chatUserId: 'u2',
          displayName: 'Bob Builder',
          username: 'bob.1234',
        );
        await render(tester, theme, entry.value, page);
        final chat = Provider.of<ActiveChatController>(
          tester.element(find.byType(ChatPage)),
          listen: false,
        );
        chat
          ..currentChatUserId = 'u2'
          ..activeChat = [
            msg('1', 'u2', 'Hello there 👋', ago: const Duration(days: 2)),
            msg(
              '2',
              'me',
              'Hi! *How* are you? `code` and a [link](https://x.y)',
              ago: const Duration(days: 1),
            ),
            msg(
              '3',
              'u2',
              MessageEnvelope.locked('Encrypted for a previous session'),
              ago: const Duration(minutes: 30),
            ),
            msg(
              '4',
              'me',
              'A reply ' * 40,
              ago: const Duration(minutes: 3),
              reply: '1',
              edited: now,
            ),
            msg('5', 'me', 'quick follow-up', ago: const Duration(minutes: 2)),
          ]
          ..isPeerTyping = true
          ..isPeerOnline = true
          ..refreshUI();
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('typing…'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('secondary pages render: $label', (tester) async {
        for (final page in const [
          AccountsSettings(),
          NewChatPage(),
          SelectContactPage(),
          ChatDetailsPage(
            isGroup: false,
            chatName: 'Bob Builder',
            chatId: 'u2',
            username: 'bob.1234',
          ),
          ChatDetailsPage(
            isGroup: true,
            chatName: 'Weekend hiking crew',
            chatId: 'g1',
          ),
        ]) {
          await render(tester, theme, entry.value, page);
          expect(
            tester.takeException(),
            isNull,
            reason: page.runtimeType.toString(),
          );
        }
      });

      testWidgets('server sheet renders: $label', (tester) async {
        await render(tester, theme, entry.value, const LoginPage());
        await tester.ensureVisible(find.text('Elephant Cloud'));
        await tester.tap(find.text('Elephant Cloud'));
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('Use Elephant Cloud'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('settings pages render: $label', (tester) async {
        for (final page in const [
          AppearanceSettings(),
          PrivacySecuritySettingsPage(),
          HelpAboutPage(),
        ]) {
          await render(tester, theme, entry.value, page);
          expect(tester.takeException(), isNull);
        }
      });
    }
  }
}
