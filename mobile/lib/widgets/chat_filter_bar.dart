import 'package:flutter/material.dart';

import '../models/chat_folder.dart';
import '../themes/app_themes.dart';

/// The row of filters above the chat list: All, Unread, Groups, and the
/// person's folders. Long-pressing a folder opens it for editing.
class ChatFilterBar extends StatelessWidget {
  final String selected;
  final int unreadChats;
  final List<ChatFolder> folders;
  final ValueChanged<String> onSelected;
  final ValueChanged<ChatFolder> onEditFolder;

  const ChatFilterBar({
    super.key,
    required this.selected,
    required this.unreadChats,
    required this.folders,
    required this.onSelected,
    required this.onEditFolder,
  });

  @override
  Widget build(BuildContext context) {
    Widget chip(String key, String label, {VoidCallback? onLongPress}) {
      return Padding(
        padding: const EdgeInsets.only(right: Insets.sm),
        child: GestureDetector(
          onLongPress: onLongPress,
          child: ChoiceChip(
            key: ValueKey('filter-$key'),
            label: Text(label),
            selected: selected == key,
            onSelected: (_) => onSelected(key),
          ),
        ),
      );
    }

    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Insets.page),
        children: [
          chip(ChatFilter.all, 'All'),
          chip(
            ChatFilter.unread,
            unreadChats > 0 ? 'Unread $unreadChats' : 'Unread',
          ),
          chip(ChatFilter.groups, 'Groups'),
          for (final folder in folders)
            chip(
              folder.id,
              folder.name,
              onLongPress: () => onEditFolder(folder),
            ),
        ],
      ),
    );
  }
}
