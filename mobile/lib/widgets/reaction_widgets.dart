import 'package:flutter/material.dart';

import '../controllers/chat/chat_meta.dart';
import '../themes/app_themes.dart';
import 'ui/feedback.dart';

/// The reactions offered first, in the message menu.
const quickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

/// More to choose from, behind the "+" in the message menu.
const moreReactions = [
  '👍', '👎', '❤️', '🔥', '😂', '🤣', '😊', '😍', //
  '😘', '😮', '😢', '😭', '😡', '🙏', '👏', '🙌',
  '🎉', '🥳', '😎', '🤔', '😴', '🤯', '😬', '🙄',
  '👌', '✌️', '🤝', '💪', '👀', '✅', '❌', '💯',
  '💔', '😅', '🥹', '😇', '🤗', '🫡', '🫶', '🤌',
];

/// Pops the message menu with `react:<emoji>`, or `react-more`.
const reactMorePrefix = 'react-more';
const reactPrefix = 'react:';

/// A row of quick reactions at the top of the message menu. The one already
/// chosen is marked.
class ReactionPicker extends StatelessWidget {
  final String? mine;

  const ReactionPicker({super.key, this.mine});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.md, 0, Insets.md, Insets.sm),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (final emoji in quickReactions)
            _EmojiButton(
              emoji: emoji,
              selected: emoji == mine,
              onTap: () => Navigator.pop(context, '$reactPrefix$emoji'),
            ),
          Semantics(
            button: true,
            label: 'More reactions',
            excludeSemantics: true,
            child: IconButton.filledTonal(
              onPressed: () => Navigator.pop(context, reactMorePrefix),
              icon: const Icon(Icons.add_rounded),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmojiButton extends StatelessWidget {
  final String emoji;
  final bool selected;
  final VoidCallback onTap;

  const _EmojiButton({
    required this.emoji,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: 'React with $emoji',
      excludeSemantics: true,
      child: Material(
        color: selected
            ? context.colors.primary.withValues(alpha: 0.16)
            : Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 42,
            height: 42,
            child: Center(
              child: Text(emoji, style: const TextStyle(fontSize: 24)),
            ),
          ),
        ),
      ),
    );
  }
}

/// A grid of every reaction, to pick one that isn't in the quick row.
Future<String?> showEmojiGrid(BuildContext context, {String? mine}) {
  return showSheet<String>(
    context,
    builder: (sheetContext) => Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.lg,
        Insets.sm,
        Insets.lg,
        Insets.xl,
      ),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: Insets.xs,
        runSpacing: Insets.xs,
        children: [
          for (final emoji in moreReactions)
            _EmojiButton(
              emoji: emoji,
              selected: emoji == mine,
              onTap: () => Navigator.pop(sheetContext, emoji),
            ),
        ],
      ),
    ),
  );
}

/// The reactions under a message bubble. Tapping them shows who reacted.
class ReactionChips extends StatelessWidget {
  final List<ReactionGroup> groups;
  final VoidCallback onTap;

  const ReactionChips({super.key, required this.groups, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final total = groups.fold<int>(0, (sum, g) => sum + g.count);
    return Semantics(
      button: true,
      label:
          '$total ${total == 1 ? 'reaction' : 'reactions'}: '
          '${groups.map((g) => '${g.emoji} ${g.count}').join(', ')}. '
          'Show who reacted',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            for (final group in groups)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: tokens.panelFill,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: group.mine
                        ? context.colors.primary
                        : tokens.hairline,
                    width: group.mine ? 1.5 : 1,
                  ),
                ),
                child: Text(
                  group.count > 1
                      ? '${group.emoji} ${group.count}'
                      : group.emoji,
                  style: context.text.labelMedium?.copyWith(
                    fontSize: 13,
                    color: context.colors.onSurface,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Who reacted to a message, with what. Our own reaction can be tapped to
/// take it away.
Future<void> showReactionList(
  BuildContext context, {
  required List<ReactionGroup> groups,
  required String Function(String senderKey) nameOf,
  required VoidCallback onRemoveMine,
}) {
  return showSheet<void>(
    context,
    builder: (sheetContext) => Padding(
      padding: const EdgeInsets.only(bottom: Insets.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final group in groups)
            for (final who in group.by)
              ListTile(
                leading: Text(
                  group.emoji,
                  style: const TextStyle(fontSize: 26),
                ),
                title: Text(
                  who == 'me' ? 'You' : nameOf(who),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: who == 'me' ? const Text('Tap to remove') : null,
                onTap: who == 'me'
                    ? () {
                        Navigator.pop(sheetContext);
                        onRemoveMine();
                      }
                    : null,
              ),
        ],
      ),
    ),
  );
}
