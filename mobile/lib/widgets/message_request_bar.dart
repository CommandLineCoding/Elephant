import 'package:flutter/material.dart';
import 'package:mobile/themes/app_themes.dart';

/// Shown instead of the message box for a message request: someone the person
/// hasn't chatted with wrote first. Nothing is shown to them until the person
/// accepts.
class MessageRequestBar extends StatelessWidget {
  final String name;
  final VoidCallback onAccept;
  final VoidCallback onDelete;
  final VoidCallback onBlock;

  const MessageRequestBar({
    super.key,
    required this.name,
    required this.onAccept,
    required this.onDelete,
    required this.onBlock,
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
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '$name isn\'t in your chats yet. They can\'t see that you '
                'read this or when you\'re online until you accept.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: Insets.md),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: onBlock,
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                      ),
                      child: const Text('Block'),
                    ),
                  ),
                  Expanded(
                    child: TextButton(
                      onPressed: onDelete,
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                      ),
                      child: const Text('Delete'),
                    ),
                  ),
                  Expanded(
                    child: FilledButton(
                      onPressed: onAccept,
                      child: const Text('Accept'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
