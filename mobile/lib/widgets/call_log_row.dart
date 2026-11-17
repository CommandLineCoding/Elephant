import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/calls/call_log.dart';
import '../themes/app_themes.dart';

/// A call in a chat's history, e.g. "Missed voice call · 4:02 PM". Tapping it
/// calls back.
class CallLogRow extends StatelessWidget {
  final CallLogEntry entry;
  final VoidCallback? onCallBack;

  const CallLogRow({super.key, required this.entry, this.onCallBack});

  @override
  Widget build(BuildContext context) {
    final missed = entry.isMissed;
    final color = missed
        ? context.colors.error
        : context.colors.onSurfaceVariant;
    final icon = missed
        ? Icons.call_missed_rounded
        : entry.outgoing
        ? Icons.call_made_rounded
        : Icons.call_received_rounded;
    final time = DateFormat.jm().format(entry.startedAt);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.sm),
      child: Center(
        child: Semantics(
          button: onCallBack != null,
          label:
              '${entry.label}, $time${onCallBack != null ? '. Call back' : ''}',
          excludeSemantics: true,
          child: Material(
            color: context.tokens.panelFill,
            shape: StadiumBorder(
              side: BorderSide(color: context.tokens.hairline),
            ),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: onCallBack,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Insets.md,
                  vertical: Insets.sm,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 16, color: color),
                    const SizedBox(width: Insets.sm),
                    Text(
                      entry.label,
                      style: context.text.bodySmall?.copyWith(
                        color: missed ? color : context.colors.onSurface,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(width: Insets.sm),
                    Text(
                      time,
                      style: context.text.bodySmall?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
