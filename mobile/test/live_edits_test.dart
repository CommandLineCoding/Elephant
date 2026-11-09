import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/controllers/chat/active_chat_controller.dart';
import 'package:mobile/models/message.dart';

Message msg(String id, {String content = 'hello', DateTime? editedAt}) {
  return Message(
    id: id,
    senderId: 'alice',
    receiverId: 'bob',
    content: content,
    createdAt: DateTime.utc(2026, 11, 9, 10, 0),
    isRead: true,
    editedAt: editedAt,
  );
}

void main() {
  group('Message.isNewerEdit', () {
    test('a message that was never edited has no newer edit', () {
      expect(Message.isNewerEdit(null, null), isFalse);
      expect(Message.isNewerEdit(null, DateTime.utc(2026, 11, 9)), isFalse);
    });

    test('the first edit is newer than a cache that has none', () {
      expect(Message.isNewerEdit(DateTime.utc(2026, 11, 9), null), isTrue);
    });

    test('a later edit is newer, an earlier one is not', () {
      final cached = DateTime.utc(2026, 11, 9, 10, 0, 5);
      expect(
        Message.isNewerEdit(cached.add(const Duration(seconds: 1)), cached),
        isTrue,
      );
      expect(
        Message.isNewerEdit(
          cached.subtract(const Duration(seconds: 1)),
          cached,
        ),
        isFalse,
      );
    });

    // The server sends microseconds, the local database keeps milliseconds. The
    // same edit read back from each must not count as new, or it is decrypted
    // twice and a readable message turns into a placeholder.
    test(
      'the same edit is not newer just because of sub-millisecond digits',
      () {
        final fromServer = DateTime.parse('2026-11-09T10:42:13.123456Z');
        final fromLocalDb = DateTime.fromMillisecondsSinceEpoch(
          fromServer.millisecondsSinceEpoch,
        );
        expect(
          fromServer.isAfter(fromLocalDb),
          isTrue,
          reason: 'this is the trap: a plain isAfter says it changed',
        );
        expect(Message.isNewerEdit(fromServer, fromLocalDb), isFalse);
      },
    );

    test('an edit a millisecond later is newer', () {
      final cached = DateTime.parse('2026-11-09T10:42:13.123Z');
      final later = DateTime.parse('2026-11-09T10:42:13.124500Z');
      expect(Message.isNewerEdit(later, cached), isTrue);
    });
  });

  group('withEditApplied', () {
    final editedAt = DateTime.utc(2026, 11, 9, 10, 5);

    test('replaces the text and marks the message edited', () {
      final chat = [msg('a'), msg('b'), msg('c')];
      final updated = withEditApplied(chat, 'b', 'corrected', editedAt);

      expect(updated.map((m) => m.content), ['hello', 'corrected', 'hello']);
      expect(updated[1].editedAt, editedAt);
      expect(updated[1].isEdited, isTrue);
      expect(updated[0].isEdited, isFalse);
    });

    test('keeps everything else about the message', () {
      final original = msg('b');
      final edited = withEditApplied(
        [original],
        'b',
        'corrected',
        editedAt,
      ).single;
      expect(edited.id, original.id);
      expect(edited.senderId, original.senderId);
      expect(edited.receiverId, original.receiverId);
      expect(edited.createdAt, original.createdAt);
    });

    test('matches ids regardless of case', () {
      final chat = [msg('ABC-123')];
      expect(
        withEditApplied(chat, 'abc-123', 'x', editedAt).single.content,
        'x',
      );
    });

    test('returns the same list when the message is not loaded', () {
      final chat = [msg('a')];
      expect(
        identical(withEditApplied(chat, 'zzz', 'x', editedAt), chat),
        isTrue,
      );
    });

    test('does not change the list it was given', () {
      final chat = [msg('a')];
      withEditApplied(chat, 'a', 'x', editedAt);
      expect(chat.single.content, 'hello');
    });
  });
}
