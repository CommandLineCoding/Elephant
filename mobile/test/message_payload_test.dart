import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/controllers/chat/active_chat_controller.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/core/chat_markdown.dart';
import 'package:mobile/core/message_envelope.dart';
import 'package:mobile/core/message_payload.dart';
import 'package:mobile/models/inbox_item.dart';
import 'package:mobile/models/message.dart';
import 'package:mobile/services/chat/chat_event_handler.dart';
import 'package:mobile/services/ws_service.dart';

Message message(String id, String content, {String sender = 'bob'}) => Message(
  id: id,
  senderId: sender,
  receiverId: 'me',
  content: content,
  createdAt: DateTime(2026, 1, 1, 12),
  isRead: true,
);

String hiddenLine(String tag, Map<String, dynamic> json) {
  final blob = base64Url.encode(utf8.encode(jsonEncode(json)));
  return '[//]: # (elephant:v1:$tag${blob.replaceAll('=', '')})';
}

void main() {
  group('the payload format', () {
    test('round-trips a payload and its readable text', () {
      final content = MessagePayload.encode('reaction', {
        'target': 'm1',
        'emoji': '👍',
      }, text: '👍 Reacted to a message');
      final split = MessagePayload.split(content);

      expect(split.text, '👍 Reacted to a message');
      expect(split.payload?.kind, 'reaction');
      expect(split.payload?.field<String>('target'), 'm1');
      expect(split.payload?.field<String>('emoji'), '👍');
      expect(split.payload?.isAction, isTrue);
      expect(content, contains(MessagePayload.actionMarker));
    });

    test('a payload with no text is just the hidden line', () {
      final content = MessagePayload.encode('poll', {'q': 'x'}, text: '');
      expect(content, startsWith('[//]: # (elephant:v1:msg:'));
      final split = MessagePayload.split(content);
      expect(split.text, isEmpty);
      expect(split.payload?.kind, 'poll');
    });

    test('only actions carry the action marker', () {
      expect(
        MessagePayload.encode('poll', {}, text: 'a'),
        isNot(contains(MessagePayload.actionMarker)),
      );
      for (final kind in MessagePayload.actionKinds) {
        expect(
          MessagePayload.encode(kind, {}, text: 'a'),
          contains(MessagePayload.actionMarker),
        );
      }
    });

    test('data survives every base64 padding length', () {
      for (var n = 0; n < 12; n++) {
        final data = {'v': 'x' * n, 'emoji': '😀' * (n % 3)};
        final p = MessagePayload.split(
          MessagePayload.encode('contact', data, text: 't'),
        ).payload;
        expect(p?.data, data, reason: 'length $n');
      }
    });

    test('ordinary text is not a payload', () {
      for (final text in [
        'hello',
        '',
        'see [//]: # (not ours)',
        '[//]: # (elephant:v1:msg:)',
      ]) {
        final split = MessagePayload.split(text);
        expect(split.payload, isNull, reason: text);
        expect(split.text, text);
      }
    });

    test('a bad payload is left as text', () {
      final cases = {
        'not base64': 'hi\n\n[//]: # (elephant:v1:msg:@@@@)',
        'not json':
            'hi\n\n[//]: # (elephant:v1:msg:${base64Url.encode(utf8.encode('nope'))})',
        'not an object':
            'hi\n\n${hiddenLine('msg:', {}).replaceFirst(RegExp(r'msg:.*\)'), 'msg:${base64Url.encode(utf8.encode('[1]'))})')}',
        'no kind': 'hi\n\n${hiddenLine('msg:', {'a': 1})}',
        'kind too long': 'hi\n\n${hiddenLine('msg:', {'kind': 'k' * 25})}',
        'kind not a string': 'hi\n\n${hiddenLine('msg:', {'kind': 5})}',
        'unknown tag': 'hi\n\n${hiddenLine('zzz:', {'kind': 'poll'})}',
      };
      for (final entry in cases.entries) {
        final split = MessagePayload.split(entry.value);
        expect(split.payload, isNull, reason: entry.key);
        expect(split.text, entry.value, reason: entry.key);
      }
    });

    test('the tag must agree with the kind', () {
      // A visible message hidden as an "action", or the reverse, would
      // disagree with the chat list's shortcut for skipping actions.
      expect(
        MessagePayload.split(
          'x\n\n${hiddenLine('act:', {'kind': 'poll'})}',
        ).payload,
        isNull,
      );
      expect(
        MessagePayload.split(
          'x\n\n${hiddenLine('msg:', {'kind': 'reaction'})}',
        ).payload,
        isNull,
      );
    });

    test('an oversized payload is refused', () {
      final big = MessagePayload.encode('poll', {'q': 'x' * 20000}, text: 't');
      expect(MessagePayload.split(big).payload, isNull);
    });

    test('the hidden line has to be on a line of its own, at the end', () {
      final content = MessagePayload.encode('poll', {'q': 'x'}, text: 'a');
      final hidden = content.substring(content.indexOf('[//]'));
      expect(MessagePayload.split('a $hidden').payload, isNull);
      expect(MessagePayload.split('$content\nmore').payload, isNull);
    });

    test('Message reads its payload and text once', () {
      final m = message(
        'm1',
        MessagePayload.encode('vote', {'poll': 'p'}, text: 'Voted'),
      );
      expect(m.isAction, isTrue);
      expect(m.text, 'Voted');
      expect(identical(m.payload, m.payload), isTrue);
      expect(message('m2', 'plain').isAction, isFalse);
      expect(message('m2', 'plain').text, 'plain');
      expect(
        message(
          'm3',
          MessagePayload.encode('poll', {'q': 'x'}, text: 'Poll: x'),
        ).isAction,
        isFalse,
      );
    });

    test('previews never show the hidden line', () {
      final content = MessagePayload.encode('poll', {
        'q': 'x',
      }, text: '📊 Poll: x');
      expect(MessageEnvelope.preview(content), '📊 Poll: x');
      expect(
        MessageEnvelope.preview(MessageEnvelope.plain(content)),
        '📊 Poll: x',
      );
      expect(MessagePayload.readable('plain'), 'plain');
    });
  });

  testWidgets('v0.5.0 draws only the readable part of a payload', (
    tester,
  ) async {
    // The previous release renders message text as Markdown with these exact
    // settings, and has never heard of payloads.
    final content = MessagePayload.encode('reaction', {
      'target': 'm1',
      'emoji': '👍',
      'x': 'abc__def)(*',
    }, text: '👍 Reacted to a message');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownBody(
            data: prepareChatMarkdown(content),
            extensionSet: chatMarkdownExtensions,
            softLineBreak: true,
          ),
        ),
      ),
    );
    final shown = tester
        .widgetList<RichText>(find.byType(RichText))
        .map((r) => r.text.toPlainText())
        .join('|');
    expect(shown, '👍 Reacted to a message');
  });

  group('sending', () {
    test('a silent frame carries the flag, an ordinary one does not', () {
      final silent = WebSocketService.chatFrame(
        messageId: 'm',
        receiverId: 'bob',
        content: 'c',
        silent: true,
      );
      expect(silent['silent'], true);
      final ordinary = WebSocketService.chatFrame(
        messageId: 'm',
        receiverId: 'bob',
        content: 'c',
      );
      expect(ordinary['silent'], isNull);
      ordinary.removeWhere((_, v) => v == null);
      expect(ordinary.containsKey('silent'), isFalse);
    });
  });

  group('the open chat', () {
    test('hides actions from the list but keeps them', () {
      final chat = ActiveChatController()
        ..activeChat = [
          message('hello', 'hello'),
          message(
            'react',
            MessagePayload.encode('reaction', {
              'target': 'hello',
              'emoji': '👍',
            }, text: '👍 Reacted'),
          ),
          message(
            'poll',
            MessagePayload.encode('poll', {'q': 'x'}, text: '📊 Poll: x'),
          ),
        ];
      expect(chat.activeChat.map((m) => m.id), ['hello', 'react', 'poll']);
      expect(chat.visibleChat.map((m) => m.id), ['hello', 'poll']);

      chat.activeChat = [...chat.activeChat, message('more', 'more')];
      expect(chat.visibleChat.map((m) => m.id), ['hello', 'poll', 'more']);
    });
  });

  group('receiving an action', () {
    Map<String, dynamic> event(String id, String content) => {
      'type': 'chat',
      'sender_id': 'bob',
      'receiver_id': 'me',
      'message_id': id,
      'timestamp': DateTime(2026, 6).toIso8601String(),
      'content': MessageEnvelope.plain(content),
    };

    ({ActiveChatController chat, InboxController inbox, ChatEventHandler h})
    setUp({required bool open}) {
      final chat = ActiveChatController();
      if (open) chat.currentChatUserId = 'bob';
      final inbox = InboxController()
        ..inbox = [
          InboxItem(
            id: 'bob',
            title: 'Bob',
            lastMessage: 'old line',
            timestamp: DateTime(2026),
            isGroup: false,
          ),
        ];
      final h = ChatEventHandler(
        inboxController: inbox,
        activeChatController: chat,
        currentUserIdProvider: () => 'me',
      );
      return (chat: chat, inbox: inbox, h: h);
    }

    final reaction = MessagePayload.encode('reaction', {
      'target': 'm1',
      'emoji': '👍',
    }, text: '👍 Reacted to a message');

    test('it is applied to the open chat but is not a new message', () async {
      final t = setUp(open: true);
      await t.h.handleIncomingEvent(event('r1', reaction));

      expect(t.chat.activeChat.single.id, 'r1');
      expect(t.chat.visibleChat, isEmpty);
      expect(t.inbox.inbox.single.lastMessage, 'old line');
      expect(t.inbox.inbox.single.unreadCount, 0);
    });

    test('in a closed chat it is not unread either', () async {
      final t = setUp(open: false);
      await t.h.handleIncomingEvent(event('r2', reaction));

      expect(t.chat.activeChat, isEmpty);
      expect(t.inbox.inbox.single.lastMessage, 'old line');
      expect(t.inbox.inbox.single.unreadCount, 0);
    });

    test('a message that is not an action still counts', () async {
      final t = setUp(open: false);
      await t.h.handleIncomingEvent(event('m2', 'hello there'));

      expect(t.inbox.inbox.single.lastMessage, 'hello there');
      expect(t.inbox.inbox.single.unreadCount, 1);
    });

    test('a poll shows its readable text in the chat list', () async {
      final t = setUp(open: false);
      await t.h.handleIncomingEvent(
        event(
          'p1',
          MessagePayload.encode('poll', {'q': 'x'}, text: '📊 Poll: x'),
        ),
      );
      expect(t.inbox.inbox.single.lastMessage, '📊 Poll: x');
      expect(t.inbox.inbox.single.unreadCount, 1);
    });
  });
}
