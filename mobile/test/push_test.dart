import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/models/inbox_item.dart';
import 'package:mobile/services/push/push_notifier.dart';
import 'package:mobile/services/push/push_prefs.dart';
import 'package:mobile/services/push/push_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

InboxItem chat(
  String id, {
  int unread = 1,
  DateTime? at,
  String title = 'Maya Chen',
  bool group = false,
}) {
  return InboxItem(
    id: id,
    title: title,
    lastMessage: '',
    timestamp: at ?? DateTime(2026, 11, 9, 12),
    isGroup: group,
    unreadCount: unread,
  );
}

void main() {
  final since = DateTime(2026, 11, 9, 9);

  group('chatsToNotify', () {
    test('notifies about chats with unread messages', () {
      final due = chatsToNotify([chat('a'), chat('b')], {}, since: since);
      expect(due.map((c) => c.id), ['a', 'b']);
    });

    test('skips chats with nothing unread', () {
      expect(chatsToNotify([chat('a', unread: 0)], {}, since: since), isEmpty);
    });

    test('skips messages we already notified about', () {
      final item = chat('a');
      final notified = {'a': item.timestamp.millisecondsSinceEpoch};
      expect(chatsToNotify([item], notified, since: since), isEmpty);
    });

    test('notifies again when a newer message arrives', () {
      final item = chat('a', at: DateTime(2026, 11, 9, 13));
      final notified = {'a': DateTime(2026, 11, 9, 12).millisecondsSinceEpoch};
      expect(chatsToNotify([item], notified, since: since), hasLength(1));
    });

    test('ignores messages from before notifications were switched on', () {
      final old = chat('a', at: DateTime(2026, 11, 8));
      expect(chatsToNotify([old], {}, since: since), isEmpty);
    });

    test('a chat we have not notified about is judged against "since"', () {
      final fresh = chat('a', at: since.add(const Duration(minutes: 1)));
      expect(chatsToNotify([fresh], {}, since: since), hasLength(1));
    });
  });

  group('notificationText', () {
    test('names the sender and never includes message text', () {
      final text = notificationText(chat('a'), showName: true);
      expect(text.title, 'Maya Chen');
      expect(text.body, 'New message');
    });

    test('counts several unread messages', () {
      final text = notificationText(chat('a', unread: 4), showName: true);
      expect(text.body, '4 new messages');
    });

    test('hides the sender when asked', () {
      final text = notificationText(chat('a', unread: 2), showName: false);
      expect(text.title, 'Elephant');
      expect(text.body, '2 new messages');
    });

    test('falls back to the username for a chat with no display name', () {
      final item = InboxItem(
        id: 'a',
        title: '',
        username: 'maya.6583',
        lastMessage: '',
        timestamp: DateTime(2026, 11, 9),
        isGroup: false,
        unreadCount: 1,
      );
      expect(notificationText(item, showName: true).title, 'maya.6583');
    });
  });

  group('notification payload', () {
    test('round-trips the chat id', () {
      expect(chatIdFromPayload(chatPayload(chat('chat-123'))), 'chat-123');
    });

    test('rejects missing, empty and malformed payloads', () {
      for (final bad in [null, '', 'not json', '[]', '{"id": 5}', '{}']) {
        expect(chatIdFromPayload(bad), isNull, reason: 'payload: $bad');
      }
    });
  });

  group('PushPrefs', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('are off by default and show names by default', () async {
      expect(await PushPrefs.isEnabled(), isFalse);
      expect(await PushPrefs.showNames(), isTrue);
      expect(await PushPrefs.endpoint(), isNull);
      expect(await PushPrefs.lastNotified(), isEmpty);
    });

    test('remember when notifications were switched on', () async {
      final before = DateTime.now().subtract(const Duration(seconds: 1));
      await PushPrefs.setEnabled(true);

      expect(await PushPrefs.isEnabled(), isTrue);
      expect((await PushPrefs.enabledAt()).isAfter(before), isTrue);
    });

    test('store and clear the endpoint', () async {
      await PushPrefs.setEndpoint('https://ntfy.example.org/up1');
      expect(await PushPrefs.endpoint(), 'https://ntfy.example.org/up1');

      await PushPrefs.setEndpoint(null);
      expect(await PushPrefs.endpoint(), isNull);
    });

    test('store and clear what was notified', () async {
      await PushPrefs.setLastNotified({'a': 1000, 'b': 2000});
      expect(await PushPrefs.lastNotified(), {'a': 1000, 'b': 2000});

      await PushPrefs.clearLastNotified();
      expect(await PushPrefs.lastNotified(), isEmpty);
    });

    test('survive corrupt stored data', () async {
      SharedPreferences.setMockInitialValues({
        'push_last_notified': 'not json at all',
      });
      expect(await PushPrefs.lastNotified(), isEmpty);
    });
  });

  test('distributorLabel names common distributors', () {
    expect(distributorLabel('io.heckel.ntfy'), 'ntfy');
    expect(distributorLabel('org.example.unknown'), 'org.example.unknown');
  });
}
