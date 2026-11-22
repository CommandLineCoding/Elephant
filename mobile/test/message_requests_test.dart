import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/controllers/auth_state.dart';
import 'package:mobile/controllers/chat/group_details_controller.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/models/inbox_item.dart';
import 'package:mobile/pages/home/message_requests_page.dart';
import 'package:mobile/services/push/push_notifier.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/message_request_bar.dart';
import 'package:provider/provider.dart';

import 'chat_harness.dart';

InboxItem item(
  String id, {
  bool request = false,
  bool group = false,
  int unread = 1,
  DateTime? at,
}) => InboxItem(
  id: id,
  title: 'Person $id',
  lastMessage: 'hello',
  timestamp: at ?? DateTime(2026, 11, 22, 10),
  isGroup: group,
  unreadCount: unread,
  isRequest: request,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(mockPlatformChannels);

  group('an inbox item', () {
    Map<String, dynamic> json({Object? isRequest, String type = 'direct'}) => {
      'id': 'u1',
      'type': type,
      'name': 'ava.1234',
      'display_name': 'Ava',
      'last_message': 'x',
      'last_message_time': '2026-11-22T10:00:00Z',
      'sender_id': 'u1',
      'is_read': false,
      'unread_count': 2,
      'is_request': isRequest,
    };

    test('reads is_request from the server', () {
      expect(
        InboxItem.fromConversationJson(
          json(isRequest: true),
          lastMessage: 'x',
        ).isRequest,
        isTrue,
      );
      expect(
        InboxItem.fromConversationJson(
          json(isRequest: false),
          lastMessage: 'x',
        ).isRequest,
        isFalse,
      );
      // An older server doesn't say: an ordinary chat.
      expect(
        InboxItem.fromConversationJson(json(), lastMessage: 'x').isRequest,
        isFalse,
      );
    });

    test('a group is never a request', () {
      expect(
        InboxItem.fromConversationJson(
          json(isRequest: true, type: 'group'),
          lastMessage: 'x',
        ).isRequest,
        isFalse,
      );
    });

    test('keeps it through the local database and copies', () {
      final request = item('a', request: true);
      expect(InboxItem.fromMap(request.toMap()).isRequest, isTrue);
      expect(InboxItem.fromMap(item('b').toMap()).isRequest, isFalse);
      expect(request.copyWith(lastMessage: 'y').isRequest, isTrue);
      expect(request.copyWith(isRequest: false).isRequest, isFalse);
      // A row saved before requests existed has no value.
      final old = request.toMap()..remove('is_request');
      expect(InboxItem.fromMap(old).isRequest, isFalse);
    });
  });

  group('the inbox', () {
    test('keeps requests out of the chats, the badge and mark-all-read', () {
      final inbox = InboxController()
        ..inbox = [
          item('friend'),
          item('stranger', request: true),
          item('crew', group: true),
        ];
      expect(inbox.chats.map((i) => i.id), ['friend', 'crew']);
      expect(inbox.requests.map((i) => i.id), ['stranger']);
      expect(inbox.unreadChats, 2, reason: 'the request is not counted');
      expect(inbox.isRequest('stranger'), isTrue);
      expect(inbox.isRequest('friend'), isFalse);
      expect(inbox.isRequest('nobody'), isFalse);
    });

    test('accepting moves a request into the chats', () async {
      final asked = <String>[];
      final inbox = InboxController()
        ..inbox = [item('stranger', request: true)]
        ..requestAccepter = (id) async {
          asked.add(id);
          return null;
        };
      expect(inbox.chats, isEmpty);
      expect(await inbox.acceptRequest('stranger'), isNull);
      expect(asked, ['stranger']);
      expect(inbox.requests, isEmpty);
      expect(inbox.chats.map((i) => i.id), ['stranger']);
    });

    test('a request that fails to be accepted stays a request', () async {
      final inbox = InboxController()
        ..inbox = [item('stranger', request: true)]
        ..requestAccepter = (_) async => throw Exception('offline');
      expect(await inbox.acceptRequest('stranger'), isNotNull);
      expect(inbox.isRequest('stranger'), isTrue);
    });
  });

  test('a message request never gets a notification', () {
    final due = chatsToNotify(
      [item('friend'), item('stranger', request: true)],
      {},
      since: DateTime(2026, 11, 22, 9),
    );
    expect(due.map((c) => c.id), ['friend']);
  });

  group('in the app', () {
    Future<void> showRequests(WidgetTester tester, InboxController inbox) =>
        tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: inbox),
              ChangeNotifierProvider(create: (_) => GroupDetailsController()),
              ChangeNotifierProvider(create: (_) => AuthState()),
            ],
            child: MaterialApp(
              theme: AppThemes.getTheme(ThemeType.frost),
              home: const MessageRequestsPage(),
            ),
          ),
        );

    testWidgets('the requests page lists only the requests', (tester) async {
      final inbox = InboxController()
        ..inbox = [item('friend'), item('stranger', request: true)];
      await showRequests(tester, inbox);
      expect(find.text('Person stranger'), findsOne);
      expect(find.text('Person friend'), findsNothing);
    });

    testWidgets('the requests page says when there are none', (tester) async {
      await showRequests(tester, InboxController()..inbox = [item('friend')]);
      expect(find.text('No message requests'), findsOne);
    });

    testWidgets('the row on the home page shows how many', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppThemes.getTheme(ThemeType.frost),
          home: Scaffold(
            body: MessageRequestsRow(count: 3, onTap: () => tapped++),
          ),
        ),
      );
      expect(find.text('Message requests'), findsOne);
      expect(find.text('3'), findsOne);
      await tester.tap(find.text('Message requests'));
      expect(tapped, 1);
    });

    testWidgets('the bar has three actions', (tester) async {
      final pressed = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: AppThemes.getTheme(ThemeType.frost),
          home: Scaffold(
            body: MessageRequestBar(
              name: 'Ava',
              onAccept: () => pressed.add('accept'),
              onDelete: () => pressed.add('delete'),
              onBlock: () => pressed.add('block'),
            ),
          ),
        ),
      );
      for (final label in ['Accept', 'Delete', 'Block']) {
        await tester.tap(find.text(label));
      }
      expect(pressed, ['accept', 'delete', 'block']);
      expect(find.textContaining('Ava isn\'t in your chats yet'), findsOne);
    });

    testWidgets('a request chat has the bar, not the message box', (
      tester,
    ) async {
      final inbox = InboxController()
        ..hasLoadedOnce = true
        ..inbox = [item('u2', request: true)]
        ..requestAccepter = (_) async => null;
      await showTestChat(
        tester,
        messages: [testMessage('a', 'hello')],
        inbox: inbox,
      );
      expect(find.byType(MessageRequestBar), findsOne);
      expect(find.byType(TextField), findsNothing);

      await tester.tap(find.text('Accept'));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(MessageRequestBar), findsNothing);
      expect(find.byType(TextField), findsOne);
    });

    testWidgets('an ordinary chat has the message box', (tester) async {
      final inbox = InboxController()
        ..hasLoadedOnce = true
        ..inbox = [item('u2')];
      await showTestChat(
        tester,
        messages: [testMessage('a', 'hello')],
        inbox: inbox,
      );
      expect(find.byType(MessageRequestBar), findsNothing);
      expect(find.byType(TextField), findsOne);
    });
  });
}
