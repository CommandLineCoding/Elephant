import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/controllers/chat/chat_meta.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/core/message_payload.dart';
import 'package:mobile/models/message.dart';
import 'package:mobile/services/chat/chat_event_handler.dart';

import 'chat_harness.dart';

Response ok(Map<String, dynamic> data) => Response(
  requestOptions: RequestOptions(path: '/'),
  data: {'success': true, 'data': data},
);

/// Records delete requests and answers them like the server.
class Deleter {
  final List<(String, bool)> asked = [];
  Object? failWith;

  Future<Response> call(String id, {required bool forEveryone}) async {
    asked.add((id, forEveryone));
    if (failWith != null) throw failWith!;
    return ok({
      'id': id,
      if (forEveryone) 'deleted_at': '2026-05-01T10:00:00Z',
    });
  }
}

TestChat chatWith(List<Message> messages, Deleter deleter) => TestChat()
  ..currentUserIdProvider = (() => 'me')
  ..currentChatUserId = 'u2'
  ..messageDeleter = deleter.call
  ..activeChat = messages;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(mockPlatformChannels);

  group('the message model', () {
    test('reads and keeps deleted_at', () {
      final m = Message.fromJson({
        'id': 'a',
        'sender_id': 'bob',
        'content': '',
        'created_at': '2026-05-01T09:00:00Z',
        'deleted_at': '2026-05-01T10:00:00Z',
      });
      expect(m.isDeleted, isTrue);
      expect(m.deletedAt, DateTime.utc(2026, 5, 1, 10).toLocal());

      final back = Message.fromRow(m.toRow('chat'));
      expect(back.isDeleted, isTrue);
      expect(back.deletedAt, m.deletedAt);
      expect(testMessage('b', 'x').isDeleted, isFalse);
    });

    test('a deleted message with nothing left to read is not an action', () {
      final m = testMessage('a', '').copyWith(deletedAt: DateTime(2026));
      expect(m.isAction, isFalse);
      expect(m.text, '');
    });
  });

  group('showing a deletion', () {
    test('turns the message into a tombstone in place', () {
      final chat = chatWith([
        testMessage('a', 'first'),
        testMessage('b', 'oops'),
        testMessage('c', 'last'),
      ], Deleter());
      chat.applyDeletion('B', DateTime(2026, 5, 1));

      expect(chat.activeChat.map((m) => m.id), ['a', 'b', 'c']);
      expect(chat.activeChat[1].isDeleted, isTrue);
      expect(chat.activeChat[1].content, '');
      expect(chat.activeChat[0].isDeleted, isFalse);
      expect(chat.visibleChat.length, 3, reason: 'a tombstone is still shown');
    });

    test('applying it again, or to an unknown message, changes nothing', () {
      final chat = chatWith([testMessage('a', 'x')], Deleter());
      var notified = 0;
      chat.addListener(() => notified++);
      chat.applyDeletion('missing', DateTime(2026));
      expect(notified, 0);
      chat.applyDeletion('a', DateTime(2026));
      chat.applyDeletion('a', DateTime(2027));
      expect(notified, 1);
      expect(chat.activeChat.single.deletedAt, DateTime(2026));
    });

    test('a reply to a deleted message quotes nothing', () {
      final reply = Message(
        id: 'r',
        senderId: 'me',
        receiverId: 'u2',
        content: 'agreed',
        createdAt: DateTime.now(),
        isRead: true,
        replyToMessageId: 'a',
        quotedMessage: QuotedMessage(
          id: 'a',
          senderId: 'u2',
          senderDisplayName: '',
          content: 'the original',
        ),
      );
      final chat = chatWith([
        testMessage('a', 'the original'),
        reply,
      ], Deleter());
      expect(chat.activeChat.last.quotedMessage!.content, 'the original');
      chat.applyDeletion('a', DateTime(2026));
      expect(chat.activeChat.last.quotedMessage!.content, '');
    });

    test('reactions and pins follow the message but it stays a message', () {
      final chat = chatWith([testMessage('a', 'x')], Deleter());
      chat.applyDeletion('a', DateTime(2026));
      expect(chat.meta.reactionsOn('a'), isEmpty);
      expect(ChatMeta.from(chat.activeChat, 'me').pinned, isEmpty);
    });
  });

  group('deleting', () {
    test('for everyone: asks the server, then shows the tombstone', () async {
      final deleter = Deleter();
      var refreshed = '';
      final chat = chatWith([testMessage('a', 'oops', sender: 'me')], deleter)
        ..onMessageDeleted = (id) async => refreshed = id;

      expect(
        await chat.deleteMessage(chat.activeChat.first, forEveryone: true),
        isNull,
      );
      expect(deleter.asked, [('a', true)]);
      expect(chat.activeChat.single.isDeleted, isTrue);
      expect(
        chat.activeChat.single.deletedAt,
        DateTime.utc(2026, 5, 1, 10).toLocal(),
        reason: 'the time the server gave',
      );
      expect(refreshed, 'u2', reason: 'the chat list is told');
    });

    test('for me: asks the server, then removes it from the chat', () async {
      final deleter = Deleter();
      final chat = chatWith([
        testMessage('a', 'keep'),
        testMessage('b', 'theirs'),
      ], deleter);
      expect(
        await chat.deleteMessage(chat.activeChat.last, forEveryone: false),
        isNull,
      );
      expect(deleter.asked, [('b', false)]);
      expect(chat.activeChat.map((m) => m.id), ['a']);
    });

    test("someone else's message can't be deleted for everyone", () async {
      final deleter = Deleter();
      final chat = chatWith([testMessage('a', 'theirs')], deleter);
      final error = await chat.deleteMessage(
        chat.activeChat.first,
        forEveryone: true,
      );
      expect(error, contains('your own messages'));
      expect(deleter.asked, isEmpty, reason: 'never even asked');
      expect(chat.activeChat.single.isDeleted, isFalse);
    });

    test('a failed request leaves the message alone and says so', () async {
      final deleter = Deleter()
        ..failWith = DioException(
          requestOptions: RequestOptions(path: '/'),
          response: Response(
            requestOptions: RequestOptions(path: '/'),
            statusCode: 404,
            data: {'success': false, 'error': 'Message not found'},
          ),
          type: DioExceptionType.badResponse,
        );
      var refreshed = false;
      final chat = chatWith([testMessage('a', 'x', sender: 'me')], deleter)
        ..onMessageDeleted = (_) async => refreshed = true;

      final error = await chat.deleteMessage(
        chat.activeChat.first,
        forEveryone: true,
      );
      expect(error, 'Message not found');
      expect(chat.activeChat.single.isDeleted, isFalse);
      expect(refreshed, isFalse);

      deleter.failWith = Exception('offline');
      expect(
        await chat.deleteMessage(chat.activeChat.first, forEveryone: false),
        isNotNull,
      );
      expect(chat.activeChat, hasLength(1));
    });
  });

  group('when someone else deletes', () {
    Map<String, dynamic> event(String id, {String sender = 'u2'}) => {
      'type': 'message_deleted',
      'message_id': id,
      'sender_id': sender,
      'receiver_id': 'me',
      'deleted_at': '2026-05-01T10:00:00Z',
    };

    test('an open chat shows the tombstone', () async {
      final chat = chatWith([testMessage('a', 'secret')], Deleter());
      final handler = ChatEventHandler(
        inboxController: InboxController(),
        activeChatController: chat,
        currentUserIdProvider: () => 'me',
      );
      await handler.handleIncomingEvent(event('a'));
      expect(chat.activeChat.single.isDeleted, isTrue);
      expect(chat.activeChat.single.content, '');
    });

    test('a chat that is not open is left alone on screen', () async {
      final chat = chatWith([testMessage('a', 'secret')], Deleter())
        ..currentChatUserId = 'someone-else';
      final handler = ChatEventHandler(
        inboxController: InboxController(),
        activeChatController: chat,
        currentUserIdProvider: () => 'me',
      );
      await handler.handleIncomingEvent(event('a'));
      expect(chat.activeChat.single.isDeleted, isFalse);
    });

    test('our own deletion coming back is ignored', () async {
      final chat = chatWith([
        testMessage('a', 'mine', sender: 'me'),
      ], Deleter());
      final handler = ChatEventHandler(
        inboxController: InboxController(),
        activeChatController: chat,
        currentUserIdProvider: () => 'me',
      );
      // Sent by us to the open chat (e.g. echoed from another device).
      await handler.handleIncomingEvent({
        'type': 'message_deleted',
        'message_id': 'a',
        'sender_id': 'ME',
        'receiver_id': 'u2',
        'deleted_at': '2026-05-01T10:00:00Z',
      });
      expect(chat.activeChat.single.isDeleted, isFalse);
    });

    test('an incomplete event does nothing', () async {
      final chat = chatWith([testMessage('a', 'x')], Deleter());
      final handler = ChatEventHandler(
        inboxController: InboxController(),
        activeChatController: chat,
        currentUserIdProvider: () => 'me',
      );
      await handler.handleIncomingEvent({'type': 'message_deleted'});
      await handler.handleIncomingEvent({
        'type': 'message_deleted',
        'sender_id': 'u2',
        'receiver_id': 'me',
      });
      expect(chat.activeChat.single.isDeleted, isFalse);
    });
  });

  group('on the chat page', () {
    testWidgets('a deleted message shows as deleted, with only Delete', (
      tester,
    ) async {
      await showTestChat(
        tester,
        messages: [
          testMessage('a', 'hello'),
          testMessage('b', '').copyWith(deletedAt: DateTime(2026)),
        ],
      );
      expect(find.text('This message was deleted'), findsOneWidget);

      await tester.longPress(find.text('This message was deleted'));
      await tester.pumpAndSettle();
      expect(find.text('Delete'), findsOneWidget);
      for (final gone in ['Reply', 'Copy text', 'Forward', 'Pin', 'Edit']) {
        expect(find.text(gone), findsNothing, reason: gone);
      }
      expect(find.bySemanticsLabel('React with 👍'), findsNothing);
    });

    testWidgets('your own message: delete for me or for everyone', (
      tester,
    ) async {
      final deleter = Deleter();
      final chat = TestChat()..messageDeleter = deleter.call;
      await showTestChat(
        tester,
        chat: chat,
        messages: [testMessage('a', 'wrong chat', sender: 'me')],
      );
      await tester.longPress(find.text('wrong chat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Delete message?'), findsOneWidget);
      expect(find.text('Delete for me'), findsOneWidget);
      expect(find.text('Delete for everyone'), findsOneWidget);

      await tester.tap(find.text('Delete for everyone'));
      await tester.pumpAndSettle();
      expect(deleter.asked, [('a', true)]);
      expect(find.text('wrong chat'), findsNothing);
      expect(find.text('This message was deleted'), findsOneWidget);
    });

    testWidgets("someone else's message: only delete for me", (tester) async {
      final deleter = Deleter();
      final chat = TestChat()..messageDeleter = deleter.call;
      await showTestChat(
        tester,
        chat: chat,
        messages: [testMessage('a', 'their words')],
      );
      await tester.longPress(find.text('their words'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Delete for everyone'), findsNothing);

      await tester.tap(find.text('Delete for me'));
      await tester.pumpAndSettle();
      expect(deleter.asked, [('a', false)]);
      expect(find.text('their words'), findsNothing);
      expect(find.text('This message was deleted'), findsNothing);
    });

    testWidgets('a failed delete says so', (tester) async {
      final deleter = Deleter()..failWith = Exception('offline');
      final chat = TestChat()..messageDeleter = deleter.call;
      await showTestChat(
        tester,
        chat: chat,
        messages: [testMessage('a', 'stuck', sender: 'me')],
      );
      await tester.longPress(find.text('stuck'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete for everyone'));
      await tester.pumpAndSettle();
      expect(find.text('stuck'), findsOneWidget);
      expect(find.byType(SnackBar), findsOneWidget);
    });

    testWidgets("a message that hasn't been sent can't be deleted yet", (
      tester,
    ) async {
      await showTestChat(
        tester,
        messages: [testMessage('a', 'sending…', sender: 'me', pending: true)],
      );
      await tester.longPress(find.text('sending…'));
      await tester.pumpAndSettle();
      expect(find.text('Delete'), findsNothing);
    });

    testWidgets('a reply to a deleted message says it was deleted', (
      tester,
    ) async {
      final reply = Message(
        id: 'r',
        senderId: 'u2',
        receiverId: 'me',
        content: 'agreed',
        createdAt: DateTime.now(),
        isRead: true,
        replyToMessageId: 'a',
        quotedMessage: QuotedMessage(
          id: 'a',
          senderId: 'me',
          senderDisplayName: '',
          content: '',
        ),
      );
      await showTestChat(tester, messages: [reply]);
      expect(find.text('This message was deleted'), findsOneWidget);
      expect(find.text('agreed'), findsOneWidget);
    });

    testWidgets('a deleted message has no reactions and is not pinned', (
      tester,
    ) async {
      String act(String kind, Map<String, dynamic> data) =>
          MessagePayload.encode(kind, data, text: 'x');
      await showTestChat(
        tester,
        messages: [
          testMessage('a', '').copyWith(deletedAt: DateTime(2026)),
          testMessage('r', act('reaction', {'target': 'a', 'emoji': '👍'})),
          testMessage('p', act('pin', {'target': 'a', 'on': true})),
        ],
      );
      expect(find.text('This message was deleted'), findsOneWidget);
      expect(find.text('👍'), findsNothing);
      expect(find.text('Pinned message'), findsNothing);
    });
  });
}
