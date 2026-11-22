import '../models/message.dart';
import 'message_payload.dart';

/// How long messages in a chat last before they disappear.
enum DisappearAfter {
  off(0, 'Off'),
  hour(3600, '1 hour'),
  day(86400, '1 day'),
  week(604800, '1 week'),
  fourWeeks(2419200, '4 weeks');

  final int seconds;
  final String label;
  const DisappearAfter(this.seconds, this.label);

  Duration? get duration => seconds == 0 ? null : Duration(seconds: seconds);

  /// The choice for [seconds], or null if it isn't one of them.
  static DisappearAfter? fromSeconds(int seconds) {
    for (final d in values) {
      if (d.seconds == seconds) return d;
    }
    return null;
  }

  /// "1 day", as it reads in "disappear after 1 day".
  String get inSentence => label;
}

/// The payload that sets a chat's timer, and the text apps that don't know it
/// show. In a direct chat it travels end-to-end encrypted like any message, so
/// the server never learns the setting: it only learns each message's expiry.
(Map<String, dynamic>, String) timerPayload(DisappearAfter after) => (
  {'seconds': after.seconds},
  after == DisappearAfter.off
      ? '⏳ Disappearing messages turned off'
      : '⏳ Messages will disappear after ${after.inSentence}',
);

/// The setting a `timer` payload carries, or null if it isn't a valid one.
DisappearAfter? timerOf(MessagePayload? payload) {
  if (payload == null || payload.kind != 'timer') return null;
  final seconds = payload.field<int>('seconds');
  return seconds == null ? null : DisappearAfter.fromSeconds(seconds);
}

/// The chat's timer: the latest `timer` message. In a group ([isGroup]) only
/// admins can set it ([admins] are their lowercase user IDs), and until they
/// are known none counts. [messages] are oldest first.
DisappearAfter currentTimer(
  Iterable<Message> messages,
  String? myId, {
  bool isGroup = false,
  Set<String>? admins,
}) {
  var current = DisappearAfter.off;
  for (final message in messages) {
    final setting = timerOf(message.payload);
    if (setting == null) continue;
    if (isGroup) {
      final who = message.isFrom(myId)
          ? (myId ?? '').trim().toLowerCase()
          : message.senderId.trim().toLowerCase();
      if (admins == null || !admins.contains(who)) continue;
    }
    current = setting;
  }
  return current;
}

/// The line shown in a chat when someone changes the timer, such as "Ava set
/// messages to disappear after 1 day".
String timerNote(String who, DisappearAfter after) =>
    after == DisappearAfter.off
    ? '$who turned off disappearing messages'
    : '$who set messages to disappear after ${after.inSentence}';
