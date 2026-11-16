import 'package:flutter/material.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/ui/feedback.dart';
import 'package:provider/provider.dart';

/// Asks how to delete a chat, explaining each choice, and deletes it.
/// Returns true if the chat was deleted.
///
/// Direct chats offer "Delete for me" and "Delete for everyone"; the second
/// only deletes the messages you sent. Groups offer "Clear chat for me" (you
/// stay in the group).
Future<bool> confirmAndDeleteChat(
  BuildContext context, {
  required String chatId,
  required String title,
  required bool isGroup,
}) async {
  final explanation = isGroup
      ? 'Clears this group\'s messages from your account and this phone. You '
            'stay in the group, and new messages still arrive.'
      : 'Delete for me removes the chat from your account and this phone. '
            'Delete for everyone also deletes the messages you sent, for '
            '$title too. Their own messages stay with them.';

  final how = await showActionSheet<ChatDeletion>(
    context,
    header: Padding(
      padding: const EdgeInsets.fromLTRB(Insets.xl, 0, Insets.xl, Insets.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isGroup ? 'Clear $title?' : 'Delete chat with $title?',
            style: context.text.titleMedium,
          ),
          const SizedBox(height: Insets.xs),
          Text(explanation, style: context.text.bodySmall),
        ],
      ),
    ),
    actions: [
      SheetAction(
        icon: Icons.delete_outline_rounded,
        label: isGroup ? 'Clear chat for me' : 'Delete for me',
        value: ChatDeletion.forMe,
        destructive: true,
      ),
      if (!isGroup)
        const SheetAction(
          icon: Icons.delete_forever_outlined,
          label: 'Delete for everyone',
          value: ChatDeletion.forEveryone,
          destructive: true,
        ),
    ],
  );
  if (how == null || !context.mounted) return false;

  final error = await context.read<InboxController>().deleteConversation(
    chatId,
    isGroup: isGroup,
    how: how,
  );
  if (!context.mounted) return error == null;
  showSnack(
    context,
    error ??
        (how == ChatDeletion.forEveryone
            ? 'Chat deleted, and your messages removed for $title'
            : 'Chat deleted'),
    isError: error != null,
  );
  return error == null;
}

/// Asks an admin to confirm deleting a group for everyone, and deletes it.
/// Returns true if the group was deleted.
Future<bool> confirmAndDeleteGroup(
  BuildContext context, {
  required String groupId,
  required String name,
}) async {
  final confirmed = await confirmAction(
    context,
    title: 'Delete $name?',
    message:
        'This deletes the group and all its messages for every member. It '
        'can\'t be undone.',
    confirmLabel: 'Delete group',
    destructive: true,
  );
  if (!confirmed || !context.mounted) return false;
  final error = await context.read<InboxController>().deleteConversation(
    groupId,
    isGroup: true,
    how: ChatDeletion.wholeGroup,
  );
  if (context.mounted) {
    showSnack(context, error ?? 'Group deleted', isError: error != null);
  }
  return error == null;
}
