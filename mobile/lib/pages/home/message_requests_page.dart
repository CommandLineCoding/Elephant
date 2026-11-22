import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/pages/home/conversation_actions.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/home_page_widgets.dart';
import 'package:mobile/widgets/ui/components.dart';
import 'package:provider/provider.dart';

/// The row at the top of the chat list that opens [MessageRequestsPage].
class MessageRequestsRow extends StatelessWidget {
  final int count;
  final VoidCallback onTap;

  const MessageRequestsRow({
    super.key,
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Message requests, $count',
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
                  Icons.mark_email_unread_outlined,
                  color: context.colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: Insets.lg),
              Expanded(
                child: Text(
                  'Message requests',
                  style: context.text.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
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

/// First messages from people the person hasn't chatted with. Nothing here
/// makes a sound, and the sender isn't told it was read.
class MessageRequestsPage extends StatelessWidget {
  const MessageRequestsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final inbox = context.watch<InboxController>();
    final requests = inbox.requests;

    return Scaffold(
      appBar: AppBar(title: const Text('Message requests')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Insets.page,
              Insets.md,
              Insets.page,
              Insets.md,
            ),
            child: Text(
              'These people aren\'t in your chats or groups. They can\'t see '
              'that you read their message or when you\'re online, until you '
              'accept.',
              style: context.text.bodyMedium?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
          ),
          const Divider(height: 1),
          if (requests.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 80),
              child: EmptyState(
                icon: Icons.mark_email_unread_outlined,
                title: 'No message requests',
                message:
                    'First messages from people you don\'t know show here.',
              ),
            )
          else
            for (final item in requests)
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
