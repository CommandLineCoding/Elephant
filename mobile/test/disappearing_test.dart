import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/core/disappearing.dart';
import 'package:mobile/core/message_payload.dart';
import 'package:mobile/models/message.dart';
import 'package:mobile/services/expiry_sweeper.dart';
import 'package:mobile/widgets/timer_note_row.dart';

import 'chat_harness.dart';

Message timerMsg(
  String id,
  DisappearAfter after, {
  String sender = 'me',
  int minutesAgo = 10,
}) {
  final (data, text) = timerPayload(after);
  return testMessage(
    id,
    MessagePayload.encode('timer', data, text: text),
    sender: sender,
    at: DateTime.now().subtract(Duration(minutes: minutesAgo)),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(mockPlatformChannels);

  group('the timer setting', () {
    test('has the choices the server accepts, and only those', () {
      expect(DisappearAfter.values.map((d) => d.seconds), [
        0,
        3600,
        86400,
        604800,
        2419200,
      ]);
      for (final d in DisappearAfter.values) {
        expect(d.seconds == 0 || d.seconds >= 60, isTrue);
        expect(d.seconds <= 28 * 86400, isTrue);
      }
      expect(DisappearAfter.off.duration, isNull);
      expect(DisappearAfter.day.duration, const Duration(days: 1));
      expect(DisappearAfter.fromSeconds(86400), DisappearAfter.day);
      expect(DisappearAfter.fromSeconds(5), isNull);
    });

    test('round-trips through a message payload', () {
      for (final d in DisappearAfter.values) {
        expect(timerOf(timerMsg('t', d).payload), d);
      }
    });

    test('ignores a timer payload with an unknown or missing time', () {
      MessagePayload? payloadOf(Map<String, dynamic> data) => testMessage(
        'x',
        MessagePayload.encode('timer', data, text: 't'),
      ).payload;
      expect(timerOf(payloadOf({'seconds': 5})), isNull);
      expect(timerOf(payloadOf({})), isNull);
      expect(timerOf(payloadOf({'seconds': 'day'})), isNull);
      expect(timerOf(null), isNull);
      expect(
        timerOf(
          testMessage(
            'p',
            MessagePayload.encode('pin', {'id': 'a'}, text: 'p'),
          ).payload,
        ),
        isNull,
      );
    });

    test('a timer message is a visible message, not a silent action', () {
      expect(timerMsg('t', DisappearAfter.day).isAction, isFalse);
    });

    test('words the note for each change', () {
      expect(
        timerNote('Ava', DisappearAfter.day),
        'Ava set messages to disappear after 1 day',
      );
      expect(
        timerNote('You', DisappearAfter.off),
        'You turned off disappearing messages',
      );
    });
  });

  group('the current timer of a chat', () {
    test('is off with no timer message', () {
      expect(currentTimer([testMessage('a', 'hi')], 'me'), DisappearAfter.off);
    });

    test('is the latest one, whoever set it', () {
      final chat = [
        timerMsg('1', DisappearAfter.week, sender: 'u2'),
        testMessage('2', 'hi'),
        timerMsg('3', DisappearAfter.hour, sender: 'me'),
      ];
      expect(currentTimer(chat, 'me'), DisappearAfter.hour);
      expect(
        currentTimer([...chat, timerMsg('4', DisappearAfter.off)], 'me'),
        DisappearAfter.off,
      );
    });

    test('in a group only an admin can set it', () {
      final chat = [
        timerMsg('1', DisappearAfter.week, sender: 'admin'),
        timerMsg('2', DisappearAfter.hour, sender: 'rando'),
      ];
      expect(
        currentTimer(chat, 'me', isGroup: true, admins: {'admin'}),
        DisappearAfter.week,
      );
      // Until the admins are known, none counts.
      expect(currentTimer(chat, 'me', isGroup: true), DisappearAfter.off);
      // I count as an admin by my own ID.
      expect(
        currentTimer(
          [timerMsg('3', DisappearAfter.day, sender: 'me')],
          'ME ',
          isGroup: true,
          admins: {'me'},
        ),
        DisappearAfter.day,
      );
    });
  });

  group('a message with an expiry', () {
    test('reads expires_at, keeps it through the database and copies', () {
      final m = Message.fromJson({
        'id': 'a',
        'sender_id': 'bob',
        'content': 'x',
        'created_at': '2026-05-01T09:00:00Z',
        'expires_at': '2026-05-02T09:00:00Z',
      });
      expect(m.expiresAt, DateTime.utc(2026, 5, 2, 9).toLocal());
      final back = Message.fromRow(m.toRow('chat'));
      expect(back.expiresAt, m.expiresAt);
      expect(m.copyWith(content: 'y').expiresAt, m.expiresAt);
      expect(testMessage('b', 'x').expiresAt, isNull);
      expect(
        Message.fromRow(testMessage('b', 'x').toRow('c')).expiresAt,
        isNull,
      );
    });

    test('is expired exactly when its time has come', () {
      final at = DateTime(2026, 5, 2, 9);
      final m = testMessage('a', 'x');
      final withExpiry = Message(
        id: 'e',
        senderId: 'u2',
        receiverId: 'me',
        content: 'x',
        createdAt: at,
        isRead: true,
        expiresAt: at.add(const Duration(hours: 1)),
      );
      expect(m.isExpired(at), isFalse);
      expect(withExpiry.isExpired(at), isFalse);
      expect(
        withExpiry.isExpired(at.add(const Duration(minutes: 59))),
        isFalse,
      );
      expect(withExpiry.isExpired(at.add(const Duration(hours: 1))), isTrue);
      expect(withExpiry.isExpired(at.add(const Duration(days: 1))), isTrue);
    });
  });

  group('the open chat', () {
    test('turns on and off with the timer messages in it', () {
      final chat = TestChat()
        ..currentUserIdProvider = (() => 'me')
        ..currentChatUserId = 'u2'
        ..activeChat = [testMessage('a', 'hi')];
      expect(chat.disappearAfter, DisappearAfter.off);
      chat.activeChat = [...chat.activeChat, timerMsg('t', DisappearAfter.day)];
      expect(chat.disappearAfter, DisappearAfter.day);
      chat.activeChat = [...chat.activeChat, timerMsg('u', DisappearAfter.off)];
      expect(chat.disappearAfter, DisappearAfter.off);
    });

    test('setDisappearing sends a timer message to the chat', () async {
      final chat = TestChat()
        ..currentUserIdProvider = (() => 'me')
        ..currentChatUserId = 'u2';
      expect(await chat.setDisappearing(DisappearAfter.week), isNull);
      final sent = chat.sent.single;
      expect(sent.targetId, 'u2');
      expect(sent.silent, isFalse);
      expect(
        timerOf(
          Message(
            id: 'x',
            senderId: 'me',
            receiverId: 'u2',
            content: sent.text,
            createdAt: DateTime.now(),
            isRead: true,
          ).payload,
        ),
        DisappearAfter.week,
      );
      expect(chat.disappearAfter, DisappearAfter.week);
    });

    test('setDisappearing with no chat open does nothing', () async {
      final chat = TestChat();
      expect(await chat.setDisappearing(DisappearAfter.day), isNull);
      expect(chat.sent, isEmpty);
    });

    test('pruneExpired takes out only the messages whose time has come', () {
      final now = DateTime(2026, 5, 2, 12);
      Message m(String id, DateTime? expires) => Message(
        id: id,
        senderId: 'u2',
        receiverId: 'me',
        content: id,
        createdAt: now.subtract(const Duration(days: 1)),
        isRead: true,
        expiresAt: expires,
      );
      final chat = TestChat()
        ..currentUserIdProvider = (() => 'me')
        ..currentChatUserId = 'u2'
        ..activeChat = [
          m('gone', now.subtract(const Duration(seconds: 1))),
          m('due', now),
          m('later', now.add(const Duration(minutes: 1))),
          m('forever', null),
        ];
      var notified = 0;
      chat.addListener(() => notified++);
      chat.pruneExpired(now);
      expect(chat.activeChat.map((x) => x.id), ['later', 'forever']);
      expect(notified, 1);
      chat.pruneExpired(now);
      expect(notified, 1, reason: 'nothing left to take out, nothing to tell');
    });
  });

  group('the sweeper', () {
    test(
      'prunes, deletes, and tells only when something was deleted',
      () async {
        final now = DateTime(2026, 5, 2, 12);
        final deletedAt = <DateTime>[];
        final pruned = <DateTime>[];
        var told = 0;
        var count = 0;
        final sweeper = ExpirySweeper(
          clock: () => now,
          deleteExpired: (at) async {
            deletedAt.add(at);
            return count;
          },
          onSweep: pruned.add,
          onDeleted: () => told++,
        );
        await sweeper.sweep();
        expect(deletedAt, [now]);
        expect(pruned, [now]);
        expect(told, 0);
        count = 2;
        await sweeper.sweep();
        expect(told, 1);
      },
    );

    test('survives a failing delete and tries again', () async {
      var calls = 0;
      final sweeper = ExpirySweeper(
        deleteExpired: (_) async {
          calls++;
          if (calls == 1) throw StateError('db busy');
          return 1;
        },
        onSweep: (_) {},
        onDeleted: () {},
      );
      await sweeper.sweep();
      await sweeper.sweep();
      expect(calls, 2);
    });

    test('skips a pass while another is still running', () async {
      final gate = Completer<int>();
      var calls = 0;
      final sweeper = ExpirySweeper(
        deleteExpired: (_) {
          calls++;
          return gate.future;
        },
        onSweep: (_) {},
        onDeleted: () {},
      );
      final first = sweeper.sweep();
      await sweeper.sweep();
      expect(calls, 1);
      gate.complete(0);
      await first;
      await sweeper.sweep();
      expect(calls, 2);
    });

    test('runs on a timer once started, and stops when told', () async {
      var calls = 0;
      final sweeper = ExpirySweeper(
        every: const Duration(milliseconds: 20),
        deleteExpired: (_) async {
          calls++;
          return 0;
        },
        onSweep: (_) {},
        onDeleted: () {},
      )..start();
      await Future<void>.delayed(const Duration(milliseconds: 90));
      sweeper.stop();
      final atStop = calls;
      expect(atStop, greaterThan(2));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(calls, atStop);
    });
  });

  group('in the chat page', () {
    testWidgets('a timer message shows as a note, not a bubble', (
      tester,
    ) async {
      await showTestChat(
        tester,
        messages: [
          testMessage('a', 'hello'),
          timerMsg('t', DisappearAfter.day, sender: 'me'),
          timerMsg('u', DisappearAfter.off, sender: 'u2'),
        ],
      );
      expect(find.byType(TimerNoteRow), findsNWidgets(2));
      expect(find.text('You set messages to disappear after 1 day'), findsOne);
      expect(find.textContaining('turned off disappearing messages'), findsOne);
      // The payload's fallback text is not shown as a message.
      expect(find.textContaining('Messages will disappear'), findsNothing);
    });

    testWidgets('the menu sets the timer and marks the current one', (
      tester,
    ) async {
      final chat = await showTestChat(
        tester,
        messages: [testMessage('a', 'hello')],
      );
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Disappearing messages'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.check_rounded), findsOne);
      await tester.tap(find.text('1 week'));
      await tester.pumpAndSettle();
      expect(chat.disappearAfter, DisappearAfter.week);
      expect(chat.sent, hasLength(1));

      // Choosing what is already set sends nothing.
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Disappearing messages'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1 week'));
      await tester.pumpAndSettle();
      expect(chat.sent, hasLength(1));
    });

    testWidgets('in a group only an admin sees the menu entry', (tester) async {
      await showTestChat(
        tester,
        chatId: 'g1',
        isGroup: true,
        messages: [testMessage('a', 'hello')],
        members: [testMember('me', 'Me'), testMember('u2', 'Bob', admin: true)],
        chat: TestChat()..updateGroupAdmins({'u2'}),
      );
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      expect(find.text('Disappearing messages'), findsNothing);
      expect(find.text('Clear chat'), findsOne);
    });

    testWidgets('a group admin does see it', (tester) async {
      await showTestChat(
        tester,
        chatId: 'g1',
        isGroup: true,
        messages: [testMessage('a', 'hello')],
        members: [testMember('me', 'Me', admin: true)],
        chat: TestChat()..updateGroupAdmins({'me'}),
      );
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      expect(find.text('Disappearing messages'), findsOne);
    });
  });
}
