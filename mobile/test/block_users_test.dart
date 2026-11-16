import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/controllers/auth_state.dart';
import 'package:mobile/controllers/chat/active_chat_controller.dart';
import 'package:mobile/controllers/chat/chat_connection_controller.dart';
import 'package:mobile/controllers/chat/chat_search_controller.dart';
import 'package:mobile/controllers/chat/group_details_controller.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/pages/chat/block_user.dart';
import 'package:mobile/pages/chat/chat_page.dart';
import 'package:mobile/pages/settings/blocked_users.dart';
import 'package:mobile/providers/group_controller_provider.dart';
import 'package:mobile/services/blocked_users.dart';
import 'package:mobile/services/chat/chat_event_handler.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/themes/theme_provider.dart';
import 'package:mobile/widgets/chat_page_widgets.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const bob = BlockedUser(id: 'U-BOB', username: 'bob.1234', displayName: 'Bob');

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

  tearDown(BlockedUsers.instance.clear);

  test('the blocked list matches IDs without regard to case', () {
    BlockedUsers.instance.debugSetUsers([bob]);
    expect(BlockedUsers.instance.isBlocked('u-bob'), isTrue);
    expect(BlockedUsers.instance.isBlocked('u-carol'), isFalse);
    BlockedUsers.instance.clear();
    expect(BlockedUsers.instance.isBlocked('u-bob'), isFalse);
  });

  test('a block that fails on the server is not recorded', () async {
    // There is no server in tests.
    final error = await BlockedUsers.instance.block(bob);
    expect(error, isNotNull);
    expect(BlockedUsers.instance.isBlocked(bob.id), isFalse);
  });

  Future<void> showChat(WidgetTester tester) async {
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
            chatUserId: bob.id,
            displayName: bob.displayName,
            username: bob.username,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('a blocked chat shows Unblock instead of the message box', (
    tester,
  ) async {
    BlockedUsers.instance.debugSetUsers([bob]);
    await showChat(tester);
    expect(find.byType(BlockedBanner), findsOneWidget);
    expect(find.byType(ChatComposer), findsNothing);
    expect(find.text('You blocked Bob.'), findsOneWidget);
  });

  testWidgets('an unblocked chat has the message box', (tester) async {
    await showChat(tester);
    expect(find.byType(ChatComposer), findsOneWidget);
    expect(find.byType(BlockedBanner), findsNothing);
  });

  Widget blockedPage() => MaterialApp(
    theme: AppThemes.getTheme(ThemeType.frost),
    home: const BlockedUsersPage(),
  );

  testWidgets('the blocked users page lists them with Unblock', (tester) async {
    BlockedUsers.instance.debugSetUsers([bob]);
    await tester.pumpWidget(blockedPage());
    await tester.pump();
    // load() fails without a server and keeps the list.
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('@bob.1234'), findsOneWidget);
    expect(find.text('Unblock'), findsOneWidget);
  });

  testWidgets('with no one blocked the page says so', (tester) async {
    await tester.pumpWidget(blockedPage());
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('No one is blocked'), findsOneWidget);
  });
}
