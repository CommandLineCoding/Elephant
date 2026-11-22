import 'package:flutter/material.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/models/inbox_item.dart';
import 'package:mobile/pages/chat/chat_details_page.dart';
import 'package:mobile/pages/chat/chat_page.dart';
import 'package:mobile/pages/chat/delete_chat.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/adaptive_shell.dart';
import 'package:mobile/services/nicknames.dart';
import 'package:mobile/widgets/ui/feedback.dart';
import 'package:provider/provider.dart';

/// Opens [item]'s chat: beside the chat list on a wide screen, over it
/// otherwise.
void openConversation(BuildContext context, InboxItem item) {
  Widget page() => ChatPage(
    // A new chat in the pane is a new page, not the old one with other
    // contents.
    key: ValueKey(item.id),
    chatUserId: item.id,
    displayName: item.title.isEmpty ? (item.username ?? '') : item.title,
    username: item.username,
    isGroup: item.isGroup,
  );
  final pane = DetailPane.maybeOf(context);
  if (pane != null) {
    pane.show(page(), chatId: item.id);
    return;
  }
  Navigator.push(context, MaterialPageRoute(builder: (_) => page()));
}

Future<void> showConversationActions(
  BuildContext context,
  InboxItem item,
) async {
  final prefs = context.read<InboxController>().prefsOf(item.id);
  final action = await showActionSheet<String>(
    context,
    header: ListTile(
      title: Text(item.shownTitle, style: context.text.titleMedium),
      subtitle: Text(item.isGroup ? 'Group' : '@${item.username ?? ''}'),
    ),
    actions: [
      const SheetAction(
        icon: Icons.chat_bubble_outline_rounded,
        label: 'Open chat',
        value: 'open',
      ),
      if (item.unreadCount > 0)
        const SheetAction(
          icon: Icons.mark_chat_read_outlined,
          label: 'Mark as read',
          value: 'read',
        ),
      // Archived chats are already out of the way, so they aren't pinned.
      if (!prefs.archived)
        SheetAction(
          icon: prefs.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
          label: prefs.isPinned ? 'Unpin' : 'Pin to top',
          value: prefs.isPinned ? 'unpin' : 'pin',
        ),
      SheetAction(
        icon: prefs.isMuted()
            ? Icons.notifications_active_outlined
            : Icons.notifications_off_outlined,
        label: prefs.isMuted() ? 'Unmute' : 'Mute',
        value: prefs.isMuted() ? 'unmute' : 'mute',
      ),
      SheetAction(
        icon: prefs.archived
            ? Icons.unarchive_outlined
            : Icons.archive_outlined,
        label: prefs.archived ? 'Unarchive' : 'Archive',
        value: prefs.archived ? 'unarchive' : 'archive',
      ),
      SheetAction(
        icon: item.isGroup
            ? Icons.info_outline_rounded
            : Icons.verified_user_outlined,
        label: item.isGroup ? 'Group info' : 'Contact & encryption',
        value: 'info',
      ),
      SheetAction(
        icon: Icons.delete_outline_rounded,
        label: item.isGroup ? 'Clear chat' : 'Delete chat',
        value: 'delete',
        destructive: true,
      ),
    ],
  );
  if (!context.mounted || action == null) return;

  switch (action) {
    case 'open':
      openConversation(context, item);
      break;
    case 'delete':
      await confirmAndDeleteChat(
        context,
        chatId: item.id,
        title: item.shownTitle.isEmpty
            ? (item.username ?? '')
            : item.shownTitle,
        isGroup: item.isGroup,
      );
      break;
    case 'read':
      await context.read<InboxController>().markReadFor(item);
      break;
    case 'pin':
      final error = await context.read<InboxController>().setPinned(
        item.id,
        true,
      );
      if (error != null && context.mounted) {
        showSnack(context, error, isError: true);
      }
      break;
    case 'unpin':
      await context.read<InboxController>().setPinned(item.id, false);
      break;
    case 'mute':
      await _chooseMute(context, item);
      break;
    case 'unmute':
      await context.read<InboxController>().unmute(item.id);
      break;
    case 'archive':
      await context.read<InboxController>().setArchived(item.id, true);
      break;
    case 'unarchive':
      await context.read<InboxController>().setArchived(item.id, false);
      break;
    case 'info':
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatDetailsPage(
            chatId: item.id,
            chatName: item.shownTitle,
            realName: item.title,
            username: item.username,
            isGroup: item.isGroup,
          ),
        ),
      );
      break;
  }
}

/// Asks how long to mute a chat for: 8 hours, a week, or always.
Future<void> _chooseMute(BuildContext context, InboxItem item) async {
  final choice = await showActionSheet<String>(
    context,
    header: Padding(
      padding: const EdgeInsets.fromLTRB(Insets.xl, 0, Insets.xl, Insets.sm),
      child: Text(
        'Mute notifications for…',
        style: context.text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      ),
    ),
    actions: const [
      SheetAction(icon: Icons.schedule_rounded, label: '8 hours', value: '8h'),
      SheetAction(icon: Icons.date_range_rounded, label: '1 week', value: '1w'),
      SheetAction(
        icon: Icons.notifications_off_outlined,
        label: 'Always',
        value: 'always',
      ),
    ],
  );
  if (choice == null || !context.mounted) return;
  await context.read<InboxController>().mute(
    item.id,
    duration: switch (choice) {
      '8h' => const Duration(hours: 8),
      '1w' => const Duration(days: 7),
      _ => null,
    },
  );
}
