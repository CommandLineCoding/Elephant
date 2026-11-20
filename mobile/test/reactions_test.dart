import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/controllers/chat/chat_meta.dart';
import 'package:mobile/core/message_payload.dart';
import 'package:mobile/services/blocked_users.dart';

import 'chat_harness.dart';

String reaction(String target, String emoji) {
  final (data, text) = ChatMeta.reactionPayload(target, emoji);
  return MessagePayload.encode('reaction', data, text: text);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(mockPlatformChannels);
  tearDown(BlockedUsers.instance.clear);
  uiTests();

  group('adding up reactions', () {
    test('groups by emoji, most used first, and finds our own', () {
      final meta = ChatMeta.from([
        testMessage('m1', 'hello'),
        testMessage('r1', reaction('m1', '👍'), sender: 'ava'),
        testMessage('r2', reaction('m1', '❤️'), sender: 'ben'),
        testMessage('r3', reaction('m1', '❤️'), sender: 'me'),
        testMessage('r4', reaction('m1', '❤️'), sender: 'cy'),
      ], 'me');

      final groups = meta.reactionsOn('m1');
      expect(groups.map((g) => g.emoji), ['❤️', '👍']);
      expect(groups.first.count, 3);
      expect(groups.first.mine, isTrue);
      expect(groups.first.by, ['ben', 'me', 'cy']);
      expect(groups.last.mine, isFalse);
      expect(meta.myReactionTo('m1'), '❤️');
      expect(meta.reactionsOn('other'), isEmpty);
    });

    test('a person has one reaction per message: the latest', () {
      final meta = ChatMeta.from([
        testMessage('r1', reaction('m1', '👍'), sender: 'ava'),
        testMessage('r2', reaction('m1', '😂'), sender: 'ava'),
      ], 'me');
      expect(meta.reactionsOn('m1').map((g) => g.emoji), ['😂']);
    });

    test('an empty reaction takes theirs away', () {
      final meta = ChatMeta.from([
        testMessage('r1', reaction('m1', '👍'), sender: 'ava'),
        testMessage('r2', reaction('m1', ''), sender: 'ava'),
      ], 'me');
      expect(meta.reactionsOn('m1'), isEmpty);
    });

    test('senders are matched without regard to case', () {
      final meta = ChatMeta.from([
        testMessage('r1', reaction('m1', '👍'), sender: 'AVA'),
        testMessage('r2', reaction('m1', '😂'), sender: 'ava'),
      ], 'me');
      expect(meta.reactionsOn('m1').single.by, ['ava']);
    });

    test('a reaction is attributed to who sent it, not who it says', () {
      final spoof = MessagePayload.encode('reaction', {
        'target': 'm1',
        'emoji': '👍',
        'sender': 'me',
        'by': 'me',
      }, text: 'x');
      final meta = ChatMeta.from([
        testMessage('r1', spoof, sender: 'ava'),
      ], 'me');
      expect(meta.myReactionTo('m1'), isNull);
      expect(meta.reactionsOn('m1').single.by, ['ava']);
    });

    test('bad reactions are ignored', () {
      final meta = ChatMeta.from([
        testMessage(
          'a',
          MessagePayload.encode('reaction', {'emoji': '👍'}, text: 'x'),
          sender: 'ava',
        ),
        testMessage(
          'b',
          MessagePayload.encode('reaction', {'target': 'm1'}, text: 'x'),
          sender: 'ava',
        ),
        testMessage(
          'c',
          MessagePayload.encode('reaction', {
            'target': 'm1',
            'emoji': 'this is not an emoji',
          }, text: 'x'),
          sender: 'ava',
        ),
        testMessage(
          'd',
          MessagePayload.encode('reaction', {
            'target': 5,
            'emoji': '👍',
          }, text: 'x'),
          sender: 'ava',
        ),
      ], 'me');
      expect(meta.reactionsOn('m1'), isEmpty);
    });

    test('multi-part emoji count as one', () {
      final meta = ChatMeta.from([
        testMessage('r1', reaction('m1', '👨‍👩‍👧'), sender: 'ava'),
      ], 'me');
      expect(meta.reactionsOn('m1').single.emoji, '👨‍👩‍👧');
    });
  });

  group('the open chat', () {
    test(
      'reacting sends a silent reaction, and the same emoji removes it',
      () async {
        final chat = TestChat()
          ..currentUserIdProvider = (() => 'me')
          ..currentChatUserId = 'g1'
          ..isCurrentChatGroup = true
          ..activeChat = [testMessage('m1', 'hello')];

        await chat.react(chat.activeChat.first, '👍');
        expect(chat.sent.single.silent, isTrue);
        expect(chat.sent.single.isGroup, isTrue);
        expect(chat.meta.myReactionTo('m1'), '👍');
        expect(chat.visibleChat.map((m) => m.id), ['m1']);

        await chat.react(chat.activeChat.first, '👍');
        expect(chat.meta.myReactionTo('m1'), isNull);

        await chat.react(chat.activeChat.first, '👍');
        await chat.react(chat.activeChat.first, '😂');
        expect(chat.meta.myReactionTo('m1'), '😂');
      },
    );
  });
}

void uiTests() {
  group('on the chat page', () {
    testWidgets('long-press offers reactions, and picking one sends it', (
      tester,
    ) async {
      final chat = await showTestChat(
        tester,
        messages: [testMessage('m1', 'good morning')],
      );
      await tester.longPress(find.text('good morning'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('React with 👍'), findsOneWidget);
      expect(find.bySemanticsLabel('More reactions'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('React with 👍'));
      await tester.pumpAndSettle();

      final sent = chat.sent.single;
      expect(sent.silent, isTrue);
      final payload = MessagePayload.split(sent.text).payload!;
      expect(payload.kind, 'reaction');
      expect(payload.field<String>('target'), 'm1');
      expect(payload.field<String>('emoji'), '👍');
      // Only the readable part shows in older apps.
      expect(MessagePayload.readable(sent.text), '👍 Reacted to a message');

      // The reaction shows under the message, and not as a message.
      expect(find.text('👍'), findsOneWidget);
      expect(find.textContaining('Reacted to a message'), findsNothing);
    });

    testWidgets('picking the same one again takes it away', (tester) async {
      final chat = await showTestChat(
        tester,
        messages: [
          testMessage('m1', 'good morning'),
          testMessage('r1', reaction('m1', '👍'), sender: 'me'),
        ],
      );
      expect(find.text('👍'), findsOneWidget);

      await tester.longPress(find.text('good morning'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('React with 👍'));
      await tester.pumpAndSettle();

      expect(
        MessagePayload.split(
          chat.sent.single.text,
        ).payload!.field<String>('emoji'),
        '',
      );
      expect(find.text('👍'), findsNothing);
    });

    testWidgets('"+" opens every reaction', (tester) async {
      final chat = await showTestChat(
        tester,
        messages: [testMessage('m1', 'good morning')],
      );
      await tester.longPress(find.text('good morning'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('More reactions'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('React with 🔥'));
      await tester.pumpAndSettle();

      expect(
        MessagePayload.split(
          chat.sent.single.text,
        ).payload!.field<String>('emoji'),
        '🔥',
      );
    });

    testWidgets('tapping reactions shows who, and our own can be removed', (
      tester,
    ) async {
      final chat = await showTestChat(
        tester,
        messages: [
          testMessage('m1', 'good morning'),
          testMessage('r1', reaction('m1', '❤️'), sender: 'me'),
          testMessage('r2', reaction('m1', '❤️'), sender: 'u2'),
        ],
      );
      expect(find.text('❤️ 2'), findsOneWidget);

      await tester.tap(find.text('❤️ 2'));
      await tester.pumpAndSettle();
      final sheet = find.byType(BottomSheet);
      expect(
        find.descendant(of: sheet, matching: find.text('You')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sheet, matching: find.text('Bob')),
        findsOneWidget,
      );

      await tester.tap(find.text('Tap to remove'));
      await tester.pumpAndSettle();
      expect(
        MessagePayload.split(
          chat.sent.single.text,
        ).payload!.field<String>('emoji'),
        '',
      );
      expect(find.text('❤️ 2'), findsNothing);
      expect(find.text('❤️'), findsOneWidget);
    });

    testWidgets("can't react to someone you blocked", (tester) async {
      BlockedUsers.instance.debugSetUsers(const [
        BlockedUser(id: 'u2', username: 'bob.1234', displayName: 'Bob'),
      ]);
      await showTestChat(tester, messages: [testMessage('m1', 'good morning')]);
      await tester.longPress(find.text('good morning'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('React with 👍'), findsNothing);
      expect(find.text('Reply'), findsOneWidget);
    });

    testWidgets("can't react to a message that hasn't been sent", (
      tester,
    ) async {
      await showTestChat(
        tester,
        messages: [testMessage('m1', 'sending…', sender: 'me', pending: true)],
      );
      await tester.longPress(find.text('sending…'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('React with 👍'), findsNothing);
    });
  });
}
