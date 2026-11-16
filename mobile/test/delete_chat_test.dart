import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/controllers/chat/active_chat_controller.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/models/inbox_item.dart';
import 'package:mobile/models/message.dart';
import 'package:mobile/pages/chat/delete_chat.dart';
import 'package:mobile/services/chat/chat_event_handler.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:provider/provider.dart';

Message _msg(String id, String sender, DateTime at) => Message(
  id: id,
  senderId: sender,
  receiverId: sender == 'me' ? 'bob' : 'me',
  content: id,
  createdAt: at,
  isRead: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final t0 = DateTime.utc(2026, 11, 17, 10);

  setUpAll(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in [
      'com.llfbandit.app_links/messages',
      'com.llfbandit.app_links/events',
      'plugins.it_nomads.com/flutter_secure_storage',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
  });

  List<Message> conversation() => [
    _msg('bob-old', 'bob', t0),
    _msg('mine', 'me', t0.add(const Duration(minutes: 1))),
    _msg('bob-at-cut', 'bob', t0.add(const Duration(minutes: 2))),
    _msg('bob-new', 'bob', t0.add(const Duration(minutes: 5))),
  ];

  test('removeMessagesFrom drops only that sender\'s earlier messages', () {
    final chat = ActiveChatController()..activeChat = conversation();
    chat.removeMessagesFrom('bob', t0.add(const Duration(minutes: 2)));
    expect(chat.activeChat.map((m) => m.id), ['mine', 'bob-new']);
  });

  test('messages_deleted removes them from the open chat', () async {
    final chat = ActiveChatController()
      ..currentChatUserId = 'bob'
      ..activeChat = conversation();
    final handler = ChatEventHandler(
      inboxController: InboxController(),
      activeChatController: chat,
      currentUserIdProvider: () => 'me',
    );
    await handler.handleIncomingEvent({
      'type': 'messages_deleted',
      'sender_id': 'bob',
      'receiver_id': 'me',
      'before': t0.add(const Duration(minutes: 2)).toIso8601String(),
    });
    expect(chat.activeChat.map((m) => m.id), ['mine', 'bob-new']);
  });

  test('group_deleted empties the open group and removes it', () async {
    final chat = ActiveChatController()
      ..currentChatUserId = 'g1'
      ..isCurrentChatGroup = true
      ..activeChat = conversation();
    final inbox = InboxController()
      ..inbox = [
        InboxItem(
          id: 'g1',
          title: 'Crew',
          lastMessage: 'hi',
          timestamp: t0,
          isGroup: true,
        ),
      ];
    final handler = ChatEventHandler(
      inboxController: inbox,
      activeChatController: chat,
      currentUserIdProvider: () => 'me',
    );
    await handler.handleIncomingEvent({
      'type': 'group_deleted',
      'group_id': 'g1',
      'deleted_by': 'admin',
    });
    expect(chat.activeChat, isEmpty);
    expect(inbox.inbox, isEmpty);
  });

  Future<void> openDeleteSheet(WidgetTester tester, {required bool isGroup}) {
    return tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => InboxController(),
        child: MaterialApp(
          theme: AppThemes.getTheme(ThemeType.frost),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => confirmAndDeleteChat(
                  context,
                  chatId: 'bob',
                  title: 'Bob',
                  isGroup: isGroup,
                ),
                child: const Text('delete'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('a direct chat offers delete for me or for everyone', (
    tester,
  ) async {
    await openDeleteSheet(tester, isGroup: false);
    await tester.tap(find.text('delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete chat with Bob?'), findsOneWidget);
    expect(find.text('Delete for me'), findsOneWidget);
    expect(find.text('Delete for everyone'), findsOneWidget);
    expect(find.textContaining('Their own messages stay'), findsOneWidget);
  });

  testWidgets('a group only offers clearing it for you', (tester) async {
    await openDeleteSheet(tester, isGroup: true);
    await tester.tap(find.text('delete'));
    await tester.pumpAndSettle();
    expect(find.text('Clear chat for me'), findsOneWidget);
    expect(find.text('Delete for everyone'), findsNothing);
  });
}
