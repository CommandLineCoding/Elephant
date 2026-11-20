/// How one chat is arranged on this phone: pinned to the top, archived, or
/// muted. Kept only on this device.
class ChatPrefs {
  /// When it was pinned, or null if it isn't.
  final DateTime? pinnedAt;
  final bool archived;

  /// Muted until then, or null if it isn't. [forever] is "always".
  final DateTime? mutedUntil;

  const ChatPrefs({this.pinnedAt, this.archived = false, this.mutedUntil});

  static const none = ChatPrefs();

  /// The time a chat muted "always" is muted until.
  static final forever = DateTime.fromMillisecondsSinceEpoch(8640000000000000);

  /// Most chats that can be pinned at once.
  static const maxPinned = 3;

  bool get isPinned => pinnedAt != null;

  bool isMuted([DateTime? now]) =>
      mutedUntil != null && mutedUntil!.isAfter(now ?? DateTime.now());

  bool get mutedForever => mutedUntil == forever;

  /// Nothing set: there's no need to store it.
  bool get isDefault => pinnedAt == null && !archived && mutedUntil == null;

  ChatPrefs copyWith({
    DateTime? pinnedAt,
    bool clearPinned = false,
    bool? archived,
    DateTime? mutedUntil,
    bool clearMuted = false,
  }) => ChatPrefs(
    pinnedAt: clearPinned ? null : (pinnedAt ?? this.pinnedAt),
    archived: archived ?? this.archived,
    mutedUntil: clearMuted ? null : (mutedUntil ?? this.mutedUntil),
  );

  Map<String, dynamic> toRow(String chatId) => {
    'chat_id': chatId,
    'pinned_at': pinnedAt?.millisecondsSinceEpoch,
    'archived': archived ? 1 : 0,
    'muted_until': mutedUntil?.millisecondsSinceEpoch,
  };

  static ChatPrefs fromRow(Map<String, dynamic> row) => ChatPrefs(
    pinnedAt: row['pinned_at'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(row['pinned_at'] as int),
    archived: (row['archived'] as int? ?? 0) == 1,
    mutedUntil: row['muted_until'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(row['muted_until'] as int),
  );
}
