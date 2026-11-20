import 'package:flutter/material.dart';

import '../core/poll.dart';
import '../themes/app_themes.dart';
import 'ui/feedback.dart';

/// A poll in the chat, ready to draw: its options, the votes so far, our own
/// picks, and what tapping does.
class PollView {
  final PollData poll;
  final PollTally tally;

  /// The options we picked.
  final Set<int> mine;

  /// Called with the option tapped. Null when voting isn't possible (e.g. the
  /// person is blocked).
  final ValueChanged<int>? onToggle;
  final VoidCallback onShowVotes;

  const PollView({
    required this.poll,
    required this.tally,
    required this.mine,
    required this.onToggle,
    required this.onShowVotes,
  });
}

/// The inside of a poll's message bubble.
class PollCard extends StatelessWidget {
  final PollView view;
  final Color textColor;

  const PollCard({super.key, required this.view, required this.textColor});

  @override
  Widget build(BuildContext context) {
    final poll = view.poll;
    final muted = textColor.withValues(alpha: 0.7);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          poll.question,
          style: TextStyle(
            color: textColor,
            fontSize: 15.5,
            fontWeight: FontWeight.w700,
            height: 1.3,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          poll.multi ? 'Select one or more' : 'Select one',
          style: TextStyle(color: muted, fontSize: 12),
        ),
        const SizedBox(height: 6),
        for (var i = 0; i < poll.options.length; i++)
          _OptionRow(
            label: poll.options[i],
            count: view.tally.countFor(i),
            share: view.tally.shareOf(i),
            selected: view.mine.contains(i),
            multi: poll.multi,
            textColor: textColor,
            onTap: view.onToggle == null ? null : () => view.onToggle!(i),
          ),
        const SizedBox(height: 4),
        Row(
          children: [
            Text(
              view.tally.voters == 0
                  ? 'No votes yet'
                  : '${view.tally.voters} ${view.tally.voters == 1 ? 'vote' : 'votes'}',
              style: TextStyle(color: muted, fontSize: 12),
            ),
            const Spacer(),
            if (view.tally.voters > 0)
              InkWell(
                onTap: view.onShowVotes,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 2,
                  ),
                  child: Text(
                    'View votes',
                    style: TextStyle(
                      color: textColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _OptionRow extends StatelessWidget {
  final String label;
  final int count;
  final double share;
  final bool selected;
  final bool multi;
  final Color textColor;
  final VoidCallback? onTap;

  const _OptionRow({
    required this.label,
    required this.count,
    required this.share,
    required this.selected,
    required this.multi,
    required this.textColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final icon = multi
        ? (selected
              ? Icons.check_box_rounded
              : Icons.check_box_outline_blank_rounded)
        : (selected
              ? Icons.radio_button_checked_rounded
              : Icons.radio_button_unchecked_rounded);
    return Semantics(
      button: onTap != null,
      selected: selected,
      label: '$label, $count ${count == 1 ? 'vote' : 'votes'}',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(icon, size: 20, color: textColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(color: textColor, fontSize: 15),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '$count',
                    style: TextStyle(
                      color: textColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 28),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: share,
                    minHeight: 5,
                    color: textColor,
                    backgroundColor: textColor.withValues(alpha: 0.18),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Who picked what, option by option.
Future<void> showPollVotes(
  BuildContext context, {
  required PollData poll,
  required PollTally tally,
  required String Function(String senderKey) nameOf,
}) {
  return showSheet<void>(
    context,
    builder: (sheetContext) => ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
      ),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(Insets.xl, 0, Insets.xl, Insets.xl),
        children: [
          Text(
            poll.question,
            style: sheetContext.text.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          for (var i = 0; i < poll.options.length; i++) ...[
            const SizedBox(height: Insets.lg),
            Row(
              children: [
                Expanded(
                  child: Text(
                    poll.options[i],
                    style: sheetContext.text.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text('${tally.countFor(i)}'),
              ],
            ),
            if (tally.votersByOption[i].isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  'No votes',
                  style: TextStyle(color: sheetContext.colors.onSurfaceVariant),
                ),
              )
            else
              for (final who in tally.votersByOption[i])
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(who == 'me' ? 'You' : nameOf(who)),
                ),
          ],
        ],
      ),
    ),
  );
}
