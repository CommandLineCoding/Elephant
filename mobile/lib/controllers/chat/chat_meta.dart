import 'package:flutter/widgets.dart' show StringCharacters;

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

  const ChatMeta._(this._reactions);

  static const empty = ChatMeta._({});

  /// Longest emoji (in user-visible characters) that counts as a reaction.
  static const maxEmojiLength = 2;

  /// The key a reaction is stored under for the person who sent [message].
  static String senderKey(Message message, String? myId) =>
      message.isFrom(myId) ? 'me' : message.senderId.trim().toLowerCase();

  /// Adds up the actions in [messages], oldest first.
  static ChatMeta from(Iterable<Message> messages, String? myId) {
    Map<String, Map<String, String>>? reactions;

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
      }
    }
    return reactions == null ? empty : ChatMeta._(reactions);
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

  /// A reaction's payload and the text apps without reactions show.
  static (Map<String, dynamic>, String) reactionPayload(
    String targetId,
    String emoji,
  ) => (
    {'target': targetId, 'emoji': emoji},
    emoji.isEmpty ? 'Removed a reaction' : '$emoji Reacted to a message',
  );
}
