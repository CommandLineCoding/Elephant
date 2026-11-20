import 'package:flutter/widgets.dart' show StringCharacters;

import '../../core/poll.dart';
import '../../models/message.dart';

/// One emoji on a message, with who reacted with it.
class ReactionGroup {
  final String emoji;

  /// Who reacted, oldest first. [mine] is true when we are one of them.
  final List<String> by;
  final bool mine;

  const ReactionGroup(this.emoji, this.by, {required this.mine});

  int get count => by.length;
}

/// What the actions (reactions, and later votes and pins) in a chat add up to.
/// It is worked out from the chat's messages, so it follows history loads,
/// offline sends and edits without any state of its own.
class ChatMeta {
  /// Message ID → who reacted → with what. Insertion order is oldest first.
  final Map<String, Map<String, String>> _reactions;

  /// The pinned messages' IDs, in the order they were pinned.
  final List<String> pinned;

  /// Poll message ID → who voted → the options they picked.
  final Map<String, Map<String, List<int>>> _votes;

  const ChatMeta._(this._reactions, this.pinned, this._votes);

  static const empty = ChatMeta._({}, [], {});

  /// Most messages a chat can have pinned. Pinning one more drops the oldest.
  static const maxPins = 3;

  /// Longest emoji (in user-visible characters) that counts as a reaction.
  static const maxEmojiLength = 2;

  /// The key a reaction is stored under for the person who sent [message].
  static String senderKey(Message message, String? myId) =>
      message.isFrom(myId) ? 'me' : message.senderId.trim().toLowerCase();

  /// Adds up the actions in [messages], oldest first.
  ///
  /// In a group ([isGroup]) only admins can pin: [admins] are their lowercase
  /// user IDs, and until they're known no pin counts.
  static ChatMeta from(
    Iterable<Message> messages,
    String? myId, {
    bool isGroup = false,
    Set<String>? admins,
  }) {
    Map<String, Map<String, String>>? reactions;
    List<String>? pins;
    Map<String, Map<String, List<int>>>? votes;

    for (final message in messages) {
      final payload = message.payload;
      if (payload == null || !payload.isAction) continue;

      if (payload.kind == 'reaction') {
        final target = payload.field<String>('target');
        final emoji = payload.field<String>('emoji');
        if (target == null || target.isEmpty || emoji == null) continue;
        if (emoji.characters.length > maxEmojiLength) continue;

        final byPerson = (reactions ??= {}).putIfAbsent(target, () => {});
        final who = senderKey(message, myId);
        // A person has one reaction per message: the latest one wins, and an
        // empty one takes theirs away.
        byPerson.remove(who);
        if (emoji.isNotEmpty) byPerson[who] = emoji;
        if (byPerson.isEmpty) reactions.remove(target);
      } else if (payload.kind == 'vote') {
        final poll = payload.field<String>('poll');
        final raw = payload.field<List>('opts');
        if (poll == null || poll.isEmpty || raw == null) continue;
        if (raw.length > PollData.maxOptions) continue;
        final picks = [
          for (final o in raw)
            if (o is int && o >= 0 && o < PollData.maxOptions) o,
        ];
        if (picks.length != raw.length) continue;

        // A person's latest vote replaces their earlier one; none withdraws it.
        final byPerson = (votes ??= {}).putIfAbsent(poll, () => {});
        final who = senderKey(message, myId);
        byPerson.remove(who);
        if (picks.isNotEmpty) byPerson[who] = picks;
        if (byPerson.isEmpty) votes.remove(poll);
      } else if (payload.kind == 'pin') {
        final target = payload.field<String>('target');
        final on = payload.field<bool>('on');
        if (target == null || target.isEmpty || on == null) continue;

        if (isGroup) {
          final who = senderKey(message, myId);
          final id = who == 'me' ? (myId ?? '').trim().toLowerCase() : who;
          if (admins == null || !admins.contains(id)) continue;
        }

        final list = pins ??= [];
        list.remove(target);
        if (on) {
          list.add(target);
          if (list.length > maxPins) list.removeAt(0);
        }
      }
    }
    if (reactions == null && votes == null && (pins == null || pins.isEmpty)) {
      return empty;
    }
    return ChatMeta._(
      reactions ?? const {},
      pins ?? const [],
      votes ?? const {},
    );
  }

  /// The reactions on a message, most used first.
  List<ReactionGroup> reactionsOn(String messageId) {
    final byPerson = _reactions[messageId];
    if (byPerson == null) return const [];

    final byEmoji = <String, List<String>>{};
    for (final entry in byPerson.entries) {
      byEmoji.putIfAbsent(entry.value, () => []).add(entry.key);
    }
    final groups = [
      for (final entry in byEmoji.entries)
        ReactionGroup(entry.key, entry.value, mine: entry.value.contains('me')),
    ];
    // Stable: ties stay in the order they were first used.
    groups.sort((a, b) => b.count.compareTo(a.count));
    return groups;
  }

  /// Our own reaction to a message, or null.
  String? myReactionTo(String messageId) => _reactions[messageId]?['me'];

  bool isPinned(String messageId) => pinned.contains(messageId);

  /// Who voted for what in a poll, adding up to [PollTally].
  PollTally tallyOf(String pollId, PollData poll) =>
      PollTally.of(poll, _votes[pollId] ?? const {});

  /// A pin's payload and the text apps without pins show.
  static (Map<String, dynamic>, String) pinPayload(String targetId, bool on) =>
      (
        {'target': targetId, 'on': on},
        on ? '📌 Pinned a message' : 'Unpinned a message',
      );

  /// A reaction's payload and the text apps without reactions show.
  static (Map<String, dynamic>, String) reactionPayload(
    String targetId,
    String emoji,
  ) => (
    {'target': targetId, 'emoji': emoji},
    emoji.isEmpty ? 'Removed a reaction' : '$emoji Reacted to a message',
  );
}
