import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/controllers/auth_state.dart';
import 'package:mobile/controllers/chat/active_chat_controller.dart';
import 'package:mobile/controllers/chat/chat_connection_controller.dart';
import 'package:mobile/controllers/chat/chat_search_controller.dart';
import 'package:mobile/controllers/chat/group_details_controller.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/models/group.dart';
import 'package:mobile/pages/chat/chat_details_page.dart';
import 'package:mobile/pages/chat/chat_page.dart';
import 'package:mobile/providers/group_controller_provider.dart';
import 'package:mobile/services/chat/chat_event_handler.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/themes/theme_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Serves a fixed member list instead of fetching it.
class _Members extends GroupDetailsController {
  _Members(List<GroupMember> members) {
    currentGroupMembers = members;
  }

  @override
  Future<void> fetchGroupMembers(String groupId) async {}
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

  testWidgets('a member can be viewed and messaged from group info', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(390, 844) * 3;
    addTearDown(tester.view.reset);

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
          ChangeNotifierProvider<GroupDetailsController>(
            create: (_) => _Members([
              GroupMember(
                userId: 'u-bob',
                username: 'bob.1234',
                displayName: 'Bob Builder',
                role: 'member',
              ),
            ]),
          ),
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
          home: const ChatDetailsPage(
            isGroup: true,
            chatName: 'Hiking crew',
            chatId: 'g1',
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    await tester.ensureVisible(find.text('Bob Builder'));
    await tester.tap(find.text('Bob Builder'));
    await tester.pumpAndSettle();
    expect(find.text('View profile'), findsOneWidget);
    expect(find.text('Send message'), findsOneWidget);

    await tester.tap(find.text('View profile'));
    await tester.pumpAndSettle();
    expect(find.text('Contact info'), findsOneWidget);
    expect(find.text('@bob.1234'), findsOneWidget);
    expect(find.text('Message'), findsOneWidget);
    expect(
      find.text('Search'),
      findsNothing,
      reason: 'there is no chat behind the profile to search',
    );

    await tester.tap(find.text('Message'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(ChatPage), findsOneWidget);
    expect(find.text('Contact info'), findsNothing);
  });
}
