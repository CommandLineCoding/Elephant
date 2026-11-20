import '../models/inbox_item.dart';

/// A folder of chats the person made. Only on this phone.
class ChatFolder {
  final String id;
  final String name;

  /// The chats in it (IDs, lower-case).
  final Set<String> chatIds;

  const ChatFolder({
    required this.id,
    required this.name,
    this.chatIds = const {},
  });

  ChatFolder copyWith({String? name, Set<String>? chatIds}) => ChatFolder(
    id: id,
    name: name ?? this.name,
    chatIds: chatIds ?? this.chatIds,
  );
}

/// Which chats the chat list shows.
class ChatFilter {
  static const all = 'all';
  static const unread = 'unread';
  static const groups = 'groups';

  static bool isBuiltIn(String key) =>
      key == all || key == unread || key == groups;

  /// The chats of [chats] that [key] lets through: a built-in filter, or the
  /// ID of one of [folders].
  static List<InboxItem> apply(
    String key,
    List<InboxItem> chats,
    List<ChatFolder> folders,
  ) {
    switch (key) {
      case all:
        return chats;
      case unread:
        return chats.where((c) => c.unreadCount > 0).toList();
      case groups:
        return chats.where((c) => c.isGroup).toList();
    }
    final folder = folders.where((f) => f.id == key).firstOrNull;
    if (folder == null) return chats;
    return chats
        .where((c) => folder.chatIds.contains(c.id.toLowerCase()))
        .toList();
  }
}
