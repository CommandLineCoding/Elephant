import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/pages/home/conversation_actions.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/home_page_widgets.dart';
import 'package:mobile/widgets/ui/components.dart';
import 'package:provider/provider.dart';

/// The row at the top of the chat list that opens [ArchivedChatsPage].
class ArchivedRow extends StatelessWidget {
  final int count;

  /// Whether any archived chat has unread messages.
  final bool unread;
  final VoidCallback onTap;

  const ArchivedRow({
    super.key,
    required this.count,
    required this.unread,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Archived chats, $count${unread ? ', with unread messages' : ''}',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.page,
            vertical: 14,
          ),
          child: Row(
            children: [
              SizedBox(
                width: 52,
                child: Icon(
                  Icons.archive_outlined,
                  color: context.colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: Insets.lg),
              Expanded(
                child: Text(
                  'Archived',
                  style: context.text.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (unread)
                Container(
                  width: 9,
                  height: 9,
                  margin: const EdgeInsets.only(right: Insets.sm),
                  decoration: BoxDecoration(
                    color: context.colors.primary,
                    shape: BoxShape.circle,
                  ),
                ),
              Text(
                '$count',
                style: context.text.labelLarge?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Chats put away from the chat list. They stay here until they're
/// unarchived (or, if switched on, a new message arrives).
class ArchivedChatsPage extends StatelessWidget {
  const ArchivedChatsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final inbox = context.watch<InboxController>();
    final chats = inbox.archivedChats;

    return Scaffold(
      appBar: AppBar(title: const Text('Archived chats')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Unarchive when a message arrives'),
            subtitle: const Text(
              'Off: archived chats stay here, even with new messages.',
            ),
            value: inbox.unarchiveOnMessage,
            onChanged: inbox.setUnarchiveOnMessage,
          ),
          const Divider(height: 1),
          if (chats.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 80),
              child: EmptyState(
                icon: Icons.archive_outlined,
                title: 'No archived chats',
                message: 'Long-press a chat and choose Archive to put it here.',
              ),
            )
          else
            for (final item in chats)
              ConversationTile(
                key: ValueKey(item.id),
                conversation: item,
                onTap: () => openConversation(context, item),
                onLongPress: () {
                  HapticFeedback.mediumImpact();
                  showConversationActions(context, item);
                },
              ),
        ],
      ),
    );
  }
}
