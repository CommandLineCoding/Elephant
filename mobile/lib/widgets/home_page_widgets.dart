import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mobile/controllers/auth_state.dart';
import 'package:mobile/widgets/adaptive_shell.dart';
import 'package:mobile/controllers/chat/group_details_controller.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/models/chat_prefs.dart';
import 'package:mobile/services/drafts.dart';
import 'package:mobile/services/nicknames.dart';
import 'package:mobile/services/privacy_settings.dart';
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
    final prefs = context.select<InboxController, ChatPrefs>(
      (inbox) => inbox.prefsOf(conversation.id),
    );
    final isMuted = prefs.isMuted();
    final isMentioned = context.select<InboxController, bool>(
      (inbox) => inbox.isMentioned(conversation.id),
    );
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

    const avatarSize = 52.0;
    final onSurface = context.colors.onSurface;
    final previewStyle = context.text.bodyMedium?.copyWith(
      color: hasUnread ? onSurface : mutedColor,
      fontWeight: hasUnread ? FontWeight.w500 : FontWeight.w400,
      fontStyle: hasMessage ? FontStyle.normal : FontStyle.italic,
    );

    final tile = InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.page,
              vertical: 12,
            ),
            child: Row(
              children: [
                ListenableBuilder(
                  listenable: Nicknames.instance,
                  builder: (context, _) => ElephantAvatar(
                    name: conversation.shownTitle,
                    seed: conversation.id,
                    isGroup: conversation.isGroup,
                    size: avatarSize,
                  ),
                ),
                const SizedBox(width: Insets.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Expanded(
                            child: ListenableBuilder(
                              listenable: Nicknames.instance,
                              builder: (context, _) => Text(
                                conversation.shownTitle.isEmpty
                                    ? (conversation.username ?? 'Unknown')
                                    : conversation.shownTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: context.text.titleMedium?.copyWith(
                                  fontWeight: hasUnread
                                      ? FontWeight.w700
                                      : FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: Insets.sm),
                          Text(
                            formatInboxTime(conversation.timestamp),
                            style: context.text.labelMedium?.copyWith(
                              color: hasUnread ? onSurface : mutedColor,
                              fontWeight: hasUnread
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      ListenableBuilder(
                        listenable: Drafts.instance,
                        builder: (context, _) {
                          final draft = Drafts.instance.of(conversation.id);
                          return Row(
                            children: [
                              if (isMe &&
                                  hasMessage &&
                                  !conversation.isGroup &&
                                  draft == null) ...[
                                DeliveryTick(
                                  isPending:
                                      conversation.lastMessageSyncStatus ==
                                      'pending',
                                  isRead:
                                      conversation.lastMessageIsRead ?? false,
                                  color: mutedColor,
                                  size: 15,
                                ),
                                const SizedBox(width: 4),
                              ],
                              Expanded(
                                child: Text.rich(
                                  TextSpan(
                                    children: [
                                      if (draft != null)
                                        TextSpan(
                                          text: 'Draft: ',
                                          style: TextStyle(
                                            fontWeight: FontWeight.w600,
                                            color: context.colors.error,
                                          ),
                                        )
                                      else if (prefix != null)
                                        TextSpan(
                                          text: '$prefix: ',
                                          style: TextStyle(
                                            fontWeight: FontWeight.w600,
                                            color: hasUnread
                                                ? onSurface
                                                : mutedColor,
                                          ),
                                        ),
                                      TextSpan(
                                        text: draft != null
                                            ? draft.text.replaceAll('\n', ' ')
                                            : preview,
                                      ),
                                    ],
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: previewStyle,
                                ),
                              ),
                              if (isMuted) ...[
                                const SizedBox(width: Insets.sm),
                                Icon(
                                  Icons.notifications_off_rounded,
                                  size: 16,
                                  color: mutedColor,
                                  semanticLabel: 'Muted',
                                ),
                              ],
                              if (prefs.isPinned) ...[
                                const SizedBox(width: Insets.sm),
                                Icon(
                                  Icons.push_pin_rounded,
                                  size: 16,
                                  color: mutedColor,
                                  semanticLabel: 'Pinned',
                                ),
                              ],
                              if (hasUnread && isMentioned) ...[
                                const SizedBox(width: Insets.sm),
                                Semantics(
                                  label: 'Mentions you',
                                  excludeSemantics: true,
                                  child: Text(
                                    '@',
                                    style: context.text.titleMedium?.copyWith(
                                      color: context.colors.primary,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              ],
                              if (hasUnread) ...[
                                const SizedBox(width: Insets.sm),
                                UnreadBadge(
                                  conversation.unreadCount,
                                  muted: isMuted,
                                ),
                              ],
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Divider(
            indent: Insets.page + avatarSize + Insets.lg,
            endIndent: 0,
            color: context.tokens.hairline,
          ),
        ],
      ),
    );

    // On a wide screen the chat that is open beside the list is marked.
    final pane = DetailPane.maybeOf(context);
    if (pane == null) return tile;
    return ValueListenableBuilder<String?>(
      valueListenable: pane.shownChat,
      child: tile,
      builder: (context, shown, child) => ColoredBox(
        color: shown == conversation.id
            ? context.colors.primary.withValues(alpha: 0.10)
            : Colors.transparent,
        child: child,
      ),
    );
  }
}

/// Clock while queued, one tick when sent, two coloured ticks when read.
class DeliveryTick extends StatelessWidget {
  final bool isPending;
  final bool isRead;

  /// Reached the other person's phone but isn't read yet: two ticks in the
  /// ordinary colour. [isRead] is two in the highlight colour.
  final bool isDelivered;
  final Color color;
  final Color? readColor;
  final double size;

  const DeliveryTick({
    super.key,
    required this.isPending,
    required this.isRead,
    required this.color,
    this.isDelivered = false,
    this.readColor,
    this.size = 16,
  });

  @override
  Widget build(BuildContext context) {
    if (isPending) {
      return Semantics(
        label: 'Sending',
        child: Icon(
          Icons.schedule_rounded,
          size: size - 2,
          color: color.withValues(alpha: 0.7),
        ),
      );
    }
    // With read receipts off, a read message shows as delivered: you don't
    // see who read yours, and nobody sees that you read theirs.
    return ListenableBuilder(
      listenable: PrivacySettings.instance,
      builder: (context, _) {
        final read = isRead && PrivacySettings.instance.readReceipts;
        final delivered = isDelivered || isRead;
        return Semantics(
          label: read ? 'Read' : (delivered ? 'Delivered' : 'Sent'),
          child: Icon(
            delivered ? Icons.done_all_rounded : Icons.done_rounded,
            size: size,
            color: read ? (readColor ?? context.tokens.readTick) : color,
          ),
        );
      },
    );
  }
}
