import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/controllers/chat/active_chat_controller.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/core/message_envelope.dart';
import 'package:mobile/models/message.dart';
import 'package:mobile/services/chat/chat_event_handler.dart';
import 'package:mobile/services/ws_service.dart';

import 'chat_harness.dart';

Message sent(String id, {DateTime? delivered, bool read = false}) => Message(
  id: id,
  senderId: 'me',
  receiverId: 'u2',
  content: 'hi',
  createdAt: DateTime.now().subtract(const Duration(minutes: 5)),
  isRead: read,
  deliveredAt: delivered,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(mockPlatformChannels);

  group('the message model', () {
    test('reads and keeps delivered_at', () {
      final m = Message.fromJson({
        'id': 'a',
        'sender_id': 'me',
        'receiver_id': 'u2',
        'content': 'hi',
        'created_at': '2026-05-01T09:00:00Z',
        'delivered_at': '2026-05-01T09:00:03Z',
      });
      expect(m.isDelivered, isTrue);
      expect(m.deliveredAt, DateTime.utc(2026, 5, 1, 9, 0, 3).toLocal());
      expect(Message.fromRow(m.toRow('u2')).deliveredAt, m.deliveredAt);
    });

    test('a message is delivered once it is, or once it is read', () {
      expect(sent('a').isDelivered, isFalse);
      expect(sent('a', delivered: DateTime(2026)).isDelivered, isTrue);
      expect(sent('a', read: true).isDelivered, isTrue);
    });
  });

  group('which messages to acknowledge', () {
    Message incoming(
      String id, {
      String receiver = 'me',
      DateTime? delivered,
      bool deleted = false,
      String sender = 'u2',
    }) => Message(
      id: id,
      senderId: sender,
      receiverId: receiver,
      content: deleted ? '' : 'hi',
      createdAt: DateTime.now(),
      isRead: false,
      deliveredAt: delivered,
      deletedAt: deleted ? DateTime(2026) : null,
    );

    test('direct messages from someone else that the server doesn\'t know', () {
      final ids = ActiveChatController.idsToAcknowledge([
        incoming('new'),
        incoming('known', delivered: DateTime(2026)),
        incoming('group', receiver: ''),
        incoming('deleted', deleted: true),
        incoming('mine', sender: 'me'),
        incoming('mine-by-id', sender: 'ME'),
        incoming('new-2', sender: 'U3'),
      ], 'me');
      expect(ids, ['new', 'new-2']);
    });

    test('nothing to acknowledge', () {
      expect(ActiveChatController.idsToAcknowledge([], 'me'), isEmpty);
    });

    test('a big page is acknowledged 100 at a time', () {
      final ids = List.generate(250, (i) => 'm$i');
      final frames = WebSocketService.deliveredFrames(ids);
      expect(frames.map((f) => (f['message_ids'] as List).length), [
        100,
        100,
        50,
      ]);
      expect(frames.every((f) => f['type'] == 'delivered'), isTrue);
      expect([for (final f in frames) ...f['message_ids'] as List], ids);
      expect(WebSocketService.deliveredFrames([]), isEmpty);
      expect(WebSocketService.deliveredFrames(['a']).single['message_ids'], [
        'a',
      ]);
    });
  });

  group('showing delivery', () {
    test('marks our messages, once', () {
      final chat = TestChat()
        ..currentUserIdProvider = (() => 'me')
        ..activeChat = [sent('a'), sent('B'), sent('c')];
      var notified = 0;
      chat.addListener(() => notified++);

      chat.applyDelivered(['a', 'b', 'missing'], DateTime(2026, 5, 1));
      expect(chat.activeChat.map((m) => m.deliveredAt != null), [
        true,
        true,
        false,
      ]);
      expect(notified, 1);

      chat.applyDelivered(['a'], DateTime(2027));
      expect(notified, 1, reason: 'already delivered');
      expect(chat.activeChat.first.deliveredAt, DateTime(2026, 5, 1));
    });
  });

  group('events', () {
    ChatEventHandler handlerFor(TestChat chat, {List<List<String>>? acks}) =>
        ChatEventHandler(
          inboxController: InboxController(),
          activeChatController: chat,
          currentUserIdProvider: () => 'me',
          acknowledge: acks?.add,
        );

    Map<String, dynamic> delivered(Object? ids, {String peer = 'u2'}) => {
      'type': 'message_delivered',
      'message_ids': ids,
      'receiver_id': peer,
      'delivered_at': '2026-05-01T10:00:00Z',
    };

    test('message_delivered updates the open chat', () async {
      final chat = TestChat()
        ..currentUserIdProvider = (() => 'me')
        ..currentChatUserId = 'u2'
        ..activeChat = [sent('a'), sent('b')];
      await handlerFor(chat).handleIncomingEvent(delivered(['a']));
      expect(
        chat.activeChat.first.deliveredAt,
        DateTime.utc(2026, 5, 1, 10).toLocal(),
      );
      expect(chat.activeChat.last.deliveredAt, isNull);
    });

    test('another chat on screen is left alone', () async {
      final chat = TestChat()
        ..currentUserIdProvider = (() => 'me')
        ..currentChatUserId = 'u3'
        ..activeChat = [sent('a')];
      await handlerFor(chat).handleIncomingEvent(delivered(['a']));
      expect(chat.activeChat.single.deliveredAt, isNull);
    });

    test('a bad event does nothing', () async {
      final chat = TestChat()
        ..currentUserIdProvider = (() => 'me')
        ..currentChatUserId = 'u2'
        ..activeChat = [sent('a')];
      final handler = handlerFor(chat);
      await handler.handleIncomingEvent({'type': 'message_delivered'});
      await handler.handleIncomingEvent(delivered('a'));
      await handler.handleIncomingEvent(delivered([]));
      await handler.handleIncomingEvent(delivered([5, null, '']));
      await handler.handleIncomingEvent({
        'type': 'message_delivered',
        'message_ids': ['a'],
      });
      expect(chat.activeChat.single.deliveredAt, isNull);
    });

    test('a direct message that arrives is acknowledged', () async {
      final acks = <List<String>>[];
      final chat = TestChat()..currentUserIdProvider = (() => 'me');
      await handlerFor(chat, acks: acks).handleIncomingEvent({
        'type': 'chat',
        'message_id': 'm1',
        'sender_id': 'u2',
        'receiver_id': 'me',
        'timestamp': DateTime(2026).toIso8601String(),
        'content': MessageEnvelope.plain('hello'),
      });
      expect(acks, [
        ['m1'],
      ]);
    });

    test('a group message is not', () async {
      final acks = <List<String>>[];
      final chat = TestChat()..currentUserIdProvider = (() => 'me');
      await handlerFor(chat, acks: acks).handleIncomingEvent({
        'type': 'chat',
        'message_id': 'm1',
        'sender_id': 'u2',
        'group_id': 'g1',
        'timestamp': DateTime(2026).toIso8601String(),
        'content': MessageEnvelope.plain('hello'),
      });
      expect(acks, isEmpty);
    });
  });

  group('the ticks', () {
    Future<void> show(WidgetTester tester, Message m) =>
        showTestChat(tester, messages: [m]);

    testWidgets('sending, sent, delivered and read look different', (
      tester,
    ) async {
      await show(tester, sent('a').copyWith(syncStatus: 'pending'));
      expect(find.bySemanticsLabel(RegExp(r'\bSending\b')), findsOneWidget);

      await show(tester, sent('a'));
      expect(find.bySemanticsLabel(RegExp(r'\bSent\b')), findsOneWidget);
      expect(find.byIcon(Icons.done_rounded), findsOneWidget);

      await show(tester, sent('a', delivered: DateTime(2026)));
      expect(find.bySemanticsLabel(RegExp(r'\bDelivered\b')), findsOneWidget);
      expect(find.byIcon(Icons.done_all_rounded), findsOneWidget);

      await show(tester, sent('a', read: true));
      expect(find.bySemanticsLabel(RegExp(r'\bRead\b')), findsOneWidget);
      expect(find.byIcon(Icons.done_all_rounded), findsOneWidget);
    });

    testWidgets('delivered and read are told apart by colour', (tester) async {
      Color? tickColor() =>
          tester.widget<Icon>(find.byIcon(Icons.done_all_rounded)).color;

      await show(tester, sent('a', delivered: DateTime(2026)));
      final delivered = tickColor();
      await show(tester, sent('a', read: true));
      expect(tickColor(), isNot(delivered));
    });

    testWidgets('a delivery that arrives updates the tick', (tester) async {
      final chat = await showTestChat(tester, messages: [sent('a')]);
      expect(find.bySemanticsLabel(RegExp(r'\bSent\b')), findsOneWidget);
      chat.applyDelivered(['a'], DateTime(2026));
      await tester.pump();
      expect(find.bySemanticsLabel(RegExp(r'\bDelivered\b')), findsOneWidget);
    });
  });
}
