import 'package:flutter/material.dart';
import 'package:mobile/services/blocked_users.dart';
import 'package:mobile/widgets/ui/feedback.dart';

/// Explains what blocking does, then blocks. Returns true if they were
/// blocked.
Future<bool> confirmAndBlock(BuildContext context, BlockedUser user) async {
  final confirmed = await confirmAction(
    context,
    title: 'Block ${user.displayName}?',
    message:
        'They won\'t be told. Their messages, typing and read receipts won\'t '
        'reach you, and neither of you will see when the other is online. '
        'Group chats you share aren\'t affected.',
    confirmLabel: 'Block',
    destructive: true,
  );
  if (!confirmed || !context.mounted) return false;
  final error = await BlockedUsers.instance.block(user);
  if (context.mounted) {
    showSnack(
      context,
      error ?? '${user.displayName} is blocked',
      isError: error != null,
    );
  }
  return error == null;
}

/// Unblocks someone. Messages they sent while blocked are not delivered
/// afterwards.
Future<void> unblock(
  BuildContext context,
  String userId,
  String displayName,
) async {
  final error = await BlockedUsers.instance.unblock(userId);
  if (context.mounted) {
    showSnack(
      context,
      error ?? '$displayName is unblocked',
      isError: error != null,
    );
  }
}

/// Shown instead of the message box in a chat with someone you blocked.
class BlockedBanner extends StatelessWidget {
  final String displayName;
  final VoidCallback onUnblock;

  const BlockedBanner({
    super.key,
    required this.displayName,
    required this.onUnblock,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        border: Border(top: BorderSide(color: theme.colorScheme.outline)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
          child: Row(
            children: [
              Icon(
                Icons.block_rounded,
                size: 20,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'You blocked $displayName.',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              TextButton(onPressed: onUnblock, child: const Text('Unblock')),
            ],
          ),
        ),
      ),
    );
  }
}
