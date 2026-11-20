import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/controllers/chat/chat_meta.dart';
import 'package:mobile/core/message_payload.dart';
import 'package:mobile/services/blocked_users.dart';

import 'chat_harness.dart';

String pin(String target, bool on) {
  final (data, text) = ChatMeta.pinPayload(target, on);
  return MessagePayload.encode('pin', data, text: text);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(mockPlatformChannels);
  tearDown(BlockedUsers.instance.clear);

  group('adding up pins', () {
    test('pins and unpins, in the order they were pinned', () {
      final meta = ChatMeta.from([
        testMessage('p1', pin('a', true)),
        testMessage('p2', pin('b', true)),
        testMessage('p3', pin('a', false)),
        testMessage('p4', pin('c', true)),
      ], 'me');
      expect(meta.pinned, ['b', 'c']);
      expect(meta.isPinned('b'), isTrue);
      expect(meta.isPinned('a'), isFalse);
    });

    test('pinning again moves it to the end', () {
      final meta = ChatMeta.from([
        testMessage('p1', pin('a', true)),
        testMessage('p2', pin('b', true)),
        testMessage('p3', pin('a', true)),
      ], 'me');
      expect(meta.pinned, ['b', 'a']);
    });

    test('a fourth pin drops the oldest', () {
      final meta = ChatMeta.from([
        for (final id in ['a', 'b', 'c', 'd'])
          testMessage('p-$id', pin(id, true)),
      ], 'me');
      expect(meta.pinned, ['b', 'c', 'd']);
    });

    test('bad pins are ignored', () {
      final meta = ChatMeta.from([
        testMessage(
          'p1',
          MessagePayload.encode('pin', {'on': true}, text: 'x'),
        ),
        testMessage(
          'p2',
          MessagePayload.encode('pin', {'target': 'a'}, text: 'x'),
        ),
        testMessage(
          'p3',
          MessagePayload.encode('pin', {'target': 'a', 'on': 'yes'}, text: 'x'),
        ),
      ], 'me');
      expect(meta.pinned, isEmpty);
    });

    test('in a group only admins can pin', () {
      final messages = [
        testMessage('p1', pin('a', true), sender: 'ADMIN-1'),
        testMessage('p2', pin('b', true), sender: 'member-1'),
        testMessage('p3', pin('c', true), sender: 'me'),
      ];
      final withAdmins = ChatMeta.from(
        messages,
        'ME-ID',
        isGroup: true,
        admins: {'admin-1', 'me-id'},
      );
      expect(withAdmins.pinned, ['a', 'c']);

      // Until the admins are known, no pin counts.
      expect(ChatMeta.from(messages, 'ME-ID', isGroup: true).pinned, isEmpty);

      // In a direct chat anyone can.
      expect(ChatMeta.from(messages, 'ME-ID').pinned, ['a', 'b', 'c']);
    });

    test('a member can not unpin an admin\'s pin', () {
      final meta = ChatMeta.from(
        [
          testMessage('p1', pin('a', true), sender: 'admin-1'),
          testMessage('p2', pin('a', false), sender: 'member-1'),
        ],
        'me',
        isGroup: true,
        admins: {'admin-1'},
      );
      expect(meta.pinned, ['a']);
    });
  });

  group('on the chat page', () {
    final messages = [
      testMessage('m1', 'the address is 12 Elm Street'),
      testMessage('m2', 'bring snacks'),
    ];

    testWidgets('pinning sends a silent pin, and the bar appears', (
      tester,
    ) async {
      final chat = await showTestChat(tester, messages: messages);
      expect(find.text('Pinned message'), findsNothing);

      await tester.longPress(find.text('the address is 12 Elm Street'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pin'));
      await tester.pumpAndSettle();

      final sent = chat.sent.single;
      expect(sent.silent, isTrue);
      final payload = MessagePayload.split(sent.text).payload!;
      expect(payload.kind, 'pin');
      expect(payload.field<String>('target'), 'm1');
      expect(payload.field<bool>('on'), isTrue);
      expect(MessagePayload.readable(sent.text), '📌 Pinned a message');

      expect(find.text('Pinned message'), findsOneWidget);
      // The text shows in the message list and in the bar.
      expect(find.text('the address is 12 Elm Street'), findsNWidgets(2));
      expect(find.textContaining('Pinned a message'), findsNothing);
    });

    testWidgets('a pinned message offers Unpin', (tester) async {
      final chat = await showTestChat(
        tester,
        messages: [...messages, testMessage('p1', pin('m2', true))],
      );
      expect(find.text('Pinned message'), findsOneWidget);

      await tester.longPress(find.text('bring snacks').first);
      await tester.pumpAndSettle();
      expect(find.text('Pin'), findsNothing);
      await tester.tap(find.text('Unpin'));
      await tester.pumpAndSettle();

      expect(
        MessagePayload.split(chat.sent.single.text).payload!.field<bool>('on'),
        isFalse,
      );
      expect(find.text('Pinned message'), findsNothing);
    });

    testWidgets('several pins cycle when the bar is tapped', (tester) async {
      await showTestChat(
        tester,
        messages: [
          ...messages,
          testMessage('p1', pin('m1', true)),
          testMessage('p2', pin('m2', true)),
        ],
      );
      // The newest pin first.
      expect(find.text('Pinned message 1 of 2'), findsOneWidget);

      await tester.tap(find.text('Pinned message 1 of 2'));
      await tester.pumpAndSettle();
      expect(find.text('Pinned message 2 of 2'), findsOneWidget);

      await tester.tap(find.text('Pinned message 2 of 2'));
      await tester.pumpAndSettle();
      expect(find.text('Pinned message 1 of 2'), findsOneWidget);
    });

    testWidgets('in a group a member can not pin, an admin can', (
      tester,
    ) async {
      final members = [
        testMember('me', 'Me'),
        testMember('u2', 'Bob', admin: true),
      ];
      await showTestChat(
        tester,
        chatId: 'g1',
        isGroup: true,
        messages: messages,
        members: members,
      );
      await tester.longPress(find.text('bring snacks'));
      await tester.pumpAndSettle();
      expect(find.text('Reply'), findsOneWidget);
      expect(find.text('Pin'), findsNothing);
    });

    testWidgets('an admin of a group sees Pin', (tester) async {
      final members = [
        testMember('me', 'Me', admin: true),
        testMember('u2', 'Bob'),
      ];
      final chat = await showTestChat(
        tester,
        chatId: 'g1',
        isGroup: true,
        messages: messages,
        members: members,
      );
      await tester.longPress(find.text('bring snacks'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pin'));
      await tester.pumpAndSettle();
      expect(chat.sent.single.isGroup, isTrue);
      expect(find.text('Pinned message'), findsOneWidget);
    });
  });
}
