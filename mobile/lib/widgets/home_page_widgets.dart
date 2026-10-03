import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mobile/controllers/auth_state.dart';
import 'package:mobile/controllers/chat/group_details_controller.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/ui/avatar.dart';
import 'package:mobile/widgets/ui/components.dart';
import 'package:provider/provider.dart';
import '../models/inbox_item.dart';

String formatInboxTime(DateTime time) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(time.year, time.month, time.day);
  final diff = today.difference(day).inDays;

  if (diff == 0) return DateFormat.jm().format(time);
  if (diff == 1) return 'Yesterday';
  if (diff < 7) return DateFormat.E().format(time);
  if (time.year == now.year) return DateFormat.MMMd().format(time);
  return DateFormat.yMMMd().format(time);
}

/// One row of the inbox: avatar, name, preview with delivery state, time and
/// unread badge.
class ConversationTile extends StatelessWidget {
  final InboxItem conversation;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const ConversationTile({
    super.key,
    required this.conversation,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final hasUnread = conversation.unreadCount > 0;
    final members = context.watch<GroupDetailsController>();

    if (conversation.isGroup && !members.hasFetchedGroup(conversation.id)) {
      Future.microtask(() {
        if (context.mounted) {
          context.read<GroupDetailsController>().preloadGroupMembers(
            conversation.id,
          );
        }
      });
    }

    final myId = context.read<AuthState>().currentUser?.id.toLowerCase();
    final sender = conversation.lastMessageSender?.trim().toLowerCase();
    final isMe = sender == 'me' || (myId != null && sender == myId);
    final hasMessage = conversation.lastMessage.isNotEmpty;

    String? prefix;
    if (hasMessage &&
        conversation.isGroup &&
        sender != null &&
        sender.isNotEmpty) {
      prefix = isMe ? 'You' : members.nameFor(sender).split(' ').first;
    }

    final preview = hasMessage
        ? conversation.lastMessage.replaceAll('\n', ' ')
        : (conversation.isGroup
              ? 'Group created. Say hello!'
              : 'No messages yet');

    final mutedColor = context.colors.onSurfaceVariant;

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.page,
          vertical: 11,
        ),
        child: Row(
          children: [
            ElephantAvatar(
              name: conversation.title,
              seed: conversation.id,
              isGroup: conversation.isGroup,
              size: 54,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          conversation.title.isEmpty
                              ? (conversation.username ?? 'Unknown')
                              : conversation.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.text.titleMedium?.copyWith(
                            fontWeight: hasUnread
                                ? FontWeight.w800
                                : FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        formatInboxTime(conversation.timestamp),
                        style: TextStyle(
                          fontSize: 12,
                          color: hasUnread
                              ? context.colors.primary
                              : mutedColor,
                          fontWeight: hasUnread
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (isMe && hasMessage && !conversation.isGroup) ...[
                        DeliveryTick(
                          isPending:
                              conversation.lastMessageSyncStatus == 'pending',
                          isRead: conversation.lastMessageIsRead ?? false,
                          color: mutedColor,
                        ),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text.rich(
                          TextSpan(
                            children: [
                              if (prefix != null)
                                TextSpan(
                                  text: '$prefix: ',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: hasUnread
                                        ? context.colors.onSurface
                                        : mutedColor,
                                  ),
                                ),
                              TextSpan(text: preview),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14.5,
                            color: hasUnread
                                ? context.colors.onSurface
                                : mutedColor,
                            fontStyle: hasMessage
                                ? FontStyle.normal
                                : FontStyle.italic,
                          ),
                        ),
                      ),
                      if (hasUnread) ...[
                        const SizedBox(width: 8),
                        UnreadBadge(conversation.unreadCount),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Clock while queued, one tick when sent, two coloured ticks when read.
class DeliveryTick extends StatelessWidget {
  final bool isPending;
  final bool isRead;
  final Color color;
  final Color? readColor;
  final double size;

  const DeliveryTick({
    super.key,
    required this.isPending,
    required this.isRead,
    required this.color,
    this.readColor,
    this.size = 16,
  });

  @override
  Widget build(BuildContext context) {
    if (isPending) {
      return Icon(
        Icons.schedule_rounded,
        size: size - 2,
        color: color.withValues(alpha: 0.7),
      );
    }
    return Icon(
      isRead ? Icons.done_all_rounded : Icons.done_rounded,
      size: size,
      color: isRead ? (readColor ?? context.glass.readTick) : color,
    );
  }
}
