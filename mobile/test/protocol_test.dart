import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/controllers/auth_state.dart';
import 'package:mobile/core/message_envelope.dart';
import 'package:mobile/models/inbox_item.dart';
import 'package:mobile/models/message.dart';
import 'package:mobile/services/ws_service.dart';

void main() {
  group('MessageEnvelope', () {
    test('round-trips plaintext group content', () {
      final wire = MessageEnvelope.plain('hello "group"\nline 2');
      final parsed = MessageEnvelope.tryParse(wire)!;
      expect(parsed.isPlaintext, isTrue);
      expect(parsed.body, 'hello "group"\nline 2');
      expect(MessageEnvelope.isUnreadable(wire), isFalse);
      expect(MessageEnvelope.preview(wire), 'hello "group"\nline 2');
    });

    test('treats Signal envelopes and placeholders as unreadable', () {
      const wire = '{"type":3,"ciphertext":"AAEC"}';
      expect(MessageEnvelope.tryParse(wire)!.type, 3);
      expect(MessageEnvelope.isUnreadable(wire), isTrue);
      expect(MessageEnvelope.preview(wire, fallback: 'locked'), 'locked');
      expect(
        MessageEnvelope.isUnreadable(MessageEnvelope.locked('nope')),
        isTrue,
      );
    });

    test('leaves ordinary text and malformed JSON alone', () {
      expect(MessageEnvelope.tryParse('just text'), isNull);
      expect(MessageEnvelope.tryParse('{"ciphertext": 5}'), isNull);
      expect(MessageEnvelope.tryParse('{broken ciphertext'), isNull);
      expect(MessageEnvelope.isUnreadable('{"note":"no envelope"}'), isFalse);
    });
  });

  group('AuthState validation mirrors the server', () {
    test('username', () {
      expect(AuthState.validateUsername('ab', isRegister: true), isNotNull);
      expect(AuthState.validateUsername('a' * 26, isRegister: true), isNotNull);
      expect(
        AuthState.validateUsername('has.dot', isRegister: true),
        isNotNull,
      );
      expect(AuthState.validateUsername('Alex42', isRegister: true), isNull);
      expect(
        AuthState.validateUsername('alex.4821', isRegister: false),
        isNull,
      );
      expect(AuthState.validateUsername('', isRegister: false), isNotNull);
    });

    test('password', () {
      expect(
        AuthState.validatePassword('1234567', isRegister: true),
        isNotNull,
      );
      expect(AuthState.validatePassword('12345678', isRegister: true), isNull);
      expect(AuthState.validatePassword('short', isRegister: false), isNull);
    });
  });

  group('Message', () {
    test('parses server history rows with edits and quotes', () {
      final msg = Message.fromJson({
        'id': 'c1',
        'sender_id': 'u1',
        'receiver_id': 'u2',
        'content': 'hi',
        'created_at': '2026-10-04T10:00:00Z',
        'is_read': true,
        'edited_at': '2026-10-04T10:05:00Z',
        'reply_to_message_id': 'c0',
        'quoted_message': {'id': 'c0', 'sender_id': 'u2', 'content': 'yo'},
      });
      expect(msg.isEdited, isTrue);
      expect(msg.replyToMessageId, 'c0');
      expect(msg.quotedMessage!.content, 'yo');
      expect(msg.isFrom('U1'), isTrue);
    });

    test('treats empty reply ids from WS events as absent', () {
      final msg = Message.fromJson({
        'message_id': 'm1',
        'sender_id': 'u1',
        'group_id': '',
        'content': 'x',
        'reply_to_message_id': '',
        'timestamp': '2026-10-04T10:00:00Z',
      });
      expect(msg.id, 'm1');
      expect(msg.replyToMessageId, isNull);
    });

    test('survives a round trip through the local table', () {
      final original = Message(
        id: 'm1',
        senderId: 'me',
        receiverId: 'chat',
        content: 'hello',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
        isRead: true,
        editedAt: DateTime.fromMillisecondsSinceEpoch(2000),
      );
      final restored = Message.fromRow(original.toRow('chat'));
      expect(restored.content, 'hello');
      expect(restored.editedAt, original.editedAt);
      expect(restored.isFrom(null), isTrue);
    });

    test('can only be edited by its author within 15 minutes', () {
      Message at(
        Duration age, {
        String sender = 'me',
        String status = 'synced',
      }) => Message(
        id: 'm',
        senderId: sender,
        receiverId: 'r',
        content: 'c',
        createdAt: DateTime.now().subtract(age),
        isRead: false,
        syncStatus: status,
      );
      expect(at(const Duration(minutes: 5)).canEdit('u1'), isTrue);
      expect(at(const Duration(minutes: 16)).canEdit('u1'), isFalse);
      expect(
        at(const Duration(minutes: 1), sender: 'u2').canEdit('u1'),
        isFalse,
      );
      expect(
        at(const Duration(minutes: 1), status: 'pending').canEdit('u1'),
        isFalse,
      );
    });
  });

  test('InboxItem maps both conversation types', () {
    final direct = InboxItem.fromConversationJson({
      'id': 'u2',
      'type': 'direct',
      'name': 'bob.1234',
      'display_name': 'Bob',
      'last_message_time': '2026-10-04T10:00:00Z',
      'sender_id': 'u1',
      'is_read': true,
      'unread_count': 2,
    }, lastMessage: 'hey');
    expect(direct.title, 'Bob');
    expect(direct.username, 'bob.1234');
    expect(direct.unreadCount, 2);
    expect(direct.lastMessageSender, 'u1');

    final group = InboxItem.fromConversationJson({
      'id': 'g1',
      'type': 'group',
      'name': 'Team',
      'display_name': '',
      'unread_count': 5,
    }, lastMessage: 'hi all');
    expect(group.isGroup, isTrue);
    expect(group.title, 'Team');
    expect(group.unreadCount, 5);
  });

  test('chat frames drop null fields and report their size', () {
    final frame = WebSocketService.chatFrame(
      messageId: 'm1',
      groupId: 'g1',
      content: MessageEnvelope.plain('hi'),
    );
    final size = WebSocketService.frameSize(frame);
    expect(frame.containsKey('receiver_id'), isFalse);
    expect(frame.containsKey('reply_to_message_id'), isFalse);
    expect(size, lessThan(200));
  });
}
