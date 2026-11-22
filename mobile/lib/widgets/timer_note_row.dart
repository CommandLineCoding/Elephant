import 'package:flutter/material.dart';
import 'package:mobile/core/disappearing.dart';
import 'package:mobile/themes/app_themes.dart';

/// A line in a chat for a change to its disappearing messages, such as "Ava set
/// messages to disappear after 1 day".
class TimerNoteRow extends StatelessWidget {
  final String who;
  final DisappearAfter after;

  const TimerNoteRow({super.key, required this.who, required this.after});

  @override
  Widget build(BuildContext context) {
    final note = timerNote(who, after);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.sm),
      child: Center(
        child: Semantics(
          label: note,
          excludeSemantics: true,
          child: DecoratedBox(
            decoration: ShapeDecoration(
              color: context.tokens.panelFill,
              shape: StadiumBorder(
                side: BorderSide(color: context.tokens.hairline),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.md,
                vertical: Insets.sm,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.timer_outlined,
                    size: 16,
                    color: context.colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: Insets.sm),
                  Flexible(
                    child: Text(
                      note,
                      textAlign: TextAlign.center,
                      style: context.text.bodySmall?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
