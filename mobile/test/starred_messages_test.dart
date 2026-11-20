import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/models/inbox_item.dart';
import 'package:mobile/models/message.dart';
import 'package:mobile/pages/chat/chat_page.dart';
import 'package:mobile/pages/chat/starred_messages_page.dart';
import 'package:mobile/services/starred_messages.dart';

import 'chat_harness.dart';

/// Starred messages kept in memory, like the database does.
class MemoryStore implements StarredStore {
  final Map<String, ({String chat, DateTime at})> stars = {};
  final Map<String, Message> messages = {};
  Object? failWith;
  int idReads = 0;
  int clock = 0;

  @override
  Future<Set<String>> ids() async {
    idReads++;
    if (failWith != null) throw failWith!;
    return stars.keys.toSet();
  }

  @override
  Future<void> set(String chatId, String messageId, bool starred) async {
    if (failWith != null) throw failWith!;
    if (starred) {
      stars[messageId] = (
        chat: chatId,
        at: DateTime(2026).add(Duration(seconds: ++clock)),
      );
    } else {
      stars.remove(messageId);
    }
  }

  @override
  Future<List<StarredEntry>> entries({String? chatId}) async {
    final all = [
      for (final e in stars.entries)
        if (messages[e.key] != null &&
            (chatId == null || e.value.chat == chatId))
          StarredEntry(
            message: messages[e.key]!,
            chatId: e.value.chat,
            starredAt: e.value.at,
          ),
    ];
    all.sort((a, b) => b.starredAt.compareTo(a.starredAt));
    return all;
  }
}

InboxItem inboxChat(String id, String title, {bool group = false}) => InboxItem(
  id: id,
  title: title,
  username: group ? null : '${title.toLowerCase()}.1234',
  lastMessage: 'x',
  timestamp: DateTime(2026),
  isGroup: group,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(mockPlatformChannels);

  late MemoryStore store;
  setUp(() {
    store = MemoryStore();
    StarredMessages.instance = StarredMessages(store: store);
  });
  tearDown(() => StarredMessages.instance = StarredMessages());

  group('the starred list', () {
    test('stars and unstars, without regard to the ID\'s case', () async {
      final stars = StarredMessages.instance;
      await stars.setStarred('u2', 'MSG-1', true);
      expect(stars.isStarred('msg-1'), isTrue);
      expect(store.stars.keys, ['MSG-1']);

      await stars.setStarred('u2', 'MSG-1', false);
      expect(stars.isStarred('msg-1'), isFalse);
      expect(store.stars, isEmpty);
    });

    test('tells listeners only when something changed', () async {
      final stars = StarredMessages.instance;
      var changes = 0;
      stars.addListener(() => changes++);
      await stars.setStarred('u2', 'a', true);
      await stars.setStarred('u2', 'a', true);
      expect(changes, 1);
      await stars.setStarred('u2', 'a', false);
      await stars.setStarred('u2', 'a', false);
      expect(changes, 2);
    });

    test('reads what was starred before, once', () async {
      store.stars['a'] = (chat: 'u2', at: DateTime(2026));
      final stars = StarredMessages.instance;
      expect(stars.isStarred('a'), isFalse);
      await stars.load();
      await stars.load();
      expect(stars.isStarred('A'), isTrue);
      expect(store.idReads, 1);
    });

    test('a store that fails does not break starring', () async {
      store.failWith = Exception('disk full');
      final stars = StarredMessages.instance;
      await stars.setStarred('u2', 'a', true);
      expect(stars.isStarred('a'), isTrue, reason: 'it still shows');
      await stars.load();
      expect(stars.isStarred('a'), isTrue);
      expect(await stars.entries(), isEmpty);
    });

    test('a failed first read is tried again', () async {
      store.stars['a'] = (chat: 'u2', at: DateTime(2026));
      store.failWith = Exception('locked');
      final stars = StarredMessages.instance;
      await stars.load();
      expect(stars.isStarred('a'), isFalse);
      store.failWith = null;
      await stars.load();
      expect(stars.isStarred('a'), isTrue);
    });

    test('forgets a message that was deleted', () async {
      final stars = StarredMessages.instance;
      await stars.setStarred('u2', 'a', true);
      await stars.forget('a');
      expect(stars.isStarred('a'), isFalse);
      expect(store.stars, isEmpty);
      await stars.forget('never-starred');
    });

    test('forgetting everything at sign-out', () async {
      final stars = StarredMessages.instance;
      await stars.setStarred('u2', 'a', true);
      stars.clear();
      expect(stars.isStarred('a'), isFalse);
    });
  });

  group('on the chat page', () {
    testWidgets('Star marks a message, and Remove star takes it off', (
      tester,
    ) async {
      await showTestChat(
        tester,
        messages: [testMessage('m1', 'remember this')],
      );
      expect(find.bySemanticsLabel(RegExp(r'\bStarred\b')), findsNothing);

      await tester.longPress(find.text('remember this'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Star'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.star_rounded), findsOneWidget);
      expect(StarredMessages.instance.isStarred('m1'), isTrue);
      expect(store.stars['m1']!.chat, 'u2');

      await tester.longPress(find.text('remember this'));
      await tester.pumpAndSettle();
      expect(find.text('Star'), findsNothing);
      await tester.tap(find.text('Remove star'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.star_rounded), findsNothing);
      expect(store.stars, isEmpty);
    });

    testWidgets(
      'a message that is deleted, or not yet sent, can not be starred',
      (tester) async {
        await showTestChat(
          tester,
          messages: [
            testMessage('a', '').copyWith(deletedAt: DateTime(2026)),
            testMessage('b', 'sending', sender: 'me', pending: true),
          ],
        );
        await tester.longPress(find.text('This message was deleted'));
        await tester.pumpAndSettle();
        expect(find.text('Star'), findsNothing);
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();

        await tester.longPress(find.text('sending'));
        await tester.pumpAndSettle();
        expect(find.text('Star'), findsNothing);
      },
    );

    testWidgets('a message deleted for everyone loses its star', (
      tester,
    ) async {
      final chat = await showTestChat(
        tester,
        messages: [testMessage('a', 'oops', sender: 'me')],
      );
      await StarredMessages.instance.setStarred('u2', 'a', true);
      chat.applyDeletion('a', DateTime(2026));
      await tester.pump();
      expect(StarredMessages.instance.isStarred('a'), isFalse);
    });
  });

  group('deleting', () {
    test('for me, forgets the star', () async {
      final chat = TestChat()
        ..currentUserIdProvider = (() => 'me')
        ..currentChatUserId = 'u2'
        ..messageDeleter = ((id, {required forEveryone}) async => Response(
          requestOptions: RequestOptions(),
          statusCode: 200,
          data: {'id': id},
        ))
        ..activeChat = [testMessage('a', 'their words')];
      await StarredMessages.instance.setStarred('u2', 'a', true);
      // Not awaited: what follows is the cache write, which needs a database.
      unawaited(chat.deleteMessage(chat.activeChat.single, forEveryone: false));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(StarredMessages.instance.isStarred('a'), isFalse);
      expect(store.stars, isEmpty);
    });
  });

  group('the starred messages page', () {
    Message stored(String id, String text, {String sender = 'u2'}) {
      final m = testMessage(id, text, sender: sender);
      store.messages[id] = m;
      return m;
    }

    Future<void> show(
      WidgetTester tester, {
      String? chatId,
      TestChat? chat,
      List<InboxItem>? inbox,
    }) async {
      await showTestChat(
        tester,
        messages: [],
        // Not the chat a tap opens, so that opening it loads its messages.
        chatId: 'elsewhere',
        chat: chat,
        inbox: InboxController()
          ..hasLoadedOnce = true
          ..inbox =
              inbox ??
              [inboxChat('u2', 'Bob'), inboxChat('g1', 'Crew', group: true)],
        wrap: (_) => StarredMessagesPage(chatId: chatId),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('says so when nothing is starred', (tester) async {
      await show(tester);
      expect(find.text('No starred messages'), findsOneWidget);
    });

    testWidgets('lists them, newest star first, with who and where', (
      tester,
    ) async {
      stored('a', 'first star');
      stored('b', 'second star', sender: 'me');
      await StarredMessages.instance.setStarred('u2', 'a', true);
      await StarredMessages.instance.setStarred('u2', 'b', true);
      await show(tester);

      expect(find.text('first star'), findsOneWidget);
      expect(find.text('second star'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('second star')).dy,
        lessThan(tester.getTopLeft(find.text('first star')).dy),
      );
      expect(find.textContaining('You ·'), findsOneWidget);
      expect(find.textContaining('Bob ·'), findsOneWidget);
    });

    testWidgets('can be limited to one chat', (tester) async {
      stored('a', 'with bob');
      store.messages['c'] = testMessage('c', 'in the crew', sender: 'u3');
      await StarredMessages.instance.setStarred('u2', 'a', true);
      await StarredMessages.instance.setStarred('g1', 'c', true);

      await show(tester, chatId: 'u2');
      expect(find.text('with bob'), findsOneWidget);
      expect(find.text('in the crew'), findsNothing);
    });

    testWidgets('skips messages whose chat is gone or that were deleted', (
      tester,
    ) async {
      stored('a', 'kept');
      stored('b', 'chat is gone');
      store.messages['d'] = testMessage(
        'd',
        '',
      ).copyWith(deletedAt: DateTime(2026));
      for (final (id, chat) in [('a', 'u2'), ('b', 'ghost'), ('d', 'u2')]) {
        await StarredMessages.instance.setStarred(chat, id, true);
      }
      await show(tester);
      expect(find.text('kept'), findsOneWidget);
      expect(find.text('chat is gone'), findsNothing);
      expect(find.byType(ListTile), findsOneWidget);
    });

    testWidgets('Remove star takes it off the list', (tester) async {
      stored('a', 'goodbye');
      await StarredMessages.instance.setStarred('u2', 'a', true);
      await show(tester);
      await tester.tap(find.byTooltip('Remove star'));
      await tester.pumpAndSettle();
      expect(find.text('goodbye'), findsNothing);
      expect(find.text('No starred messages'), findsOneWidget);
    });

    testWidgets('tapping one opens the chat at that message', (tester) async {
      stored('a', 'the starred one');
      await StarredMessages.instance.setStarred('u2', 'a', true);
      final chat = TestChat()
        ..chats['u2'] = [
          testMessage('x', 'something else'),
          testMessage('a', 'the starred one'),
        ];
      await show(tester, chat: chat);

      await tester.tap(find.byType(ListTile));
      await tester.pumpAndSettle();
      expect(find.byType(ChatPage), findsOneWidget);
      expect(chat.opened, contains('u2'));
      expect(find.text('the starred one'), findsOneWidget);
      expect(find.text("Couldn't find that message"), findsNothing);
    });

    testWidgets('a message further back is found by loading older ones', (
      tester,
    ) async {
      stored('old', 'from long ago');
      await StarredMessages.instance.setStarred('u2', 'old', true);
      final chat = TestChat()
        ..chats['u2'] = [testMessage('new', 'recent')]
        ..olderPages.addAll([
          [testMessage('p1', 'page one')],
          [testMessage('p2', 'page two')],
          [testMessage('old', 'from long ago')],
          [testMessage('p4', 'page four')],
        ]);
      await show(tester, chat: chat);

      await tester.tap(find.byType(ListTile));
      await tester.pumpAndSettle();
      expect(chat.activeChat.any((m) => m.id == 'old'), isTrue);
      expect(find.text("Couldn't find that message"), findsNothing);
    });

    testWidgets('says so when the message can not be found', (tester) async {
      stored('gone', 'lost');
      await StarredMessages.instance.setStarred('u2', 'gone', true);
      final chat = TestChat()..chats['u2'] = [testMessage('new', 'recent')];
      await show(tester, chat: chat);

      await tester.tap(find.byType(ListTile));
      await tester.pumpAndSettle();
      expect(find.text("Couldn't find that message"), findsOneWidget);
    });
  });
}
