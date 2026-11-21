import 'package:flutter/material.dart';
import 'package:mobile/services/api_services.dart';
import 'package:mobile/services/blocked_users.dart';
import 'package:mobile/services/reports.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/ui/feedback.dart';

/// What the person chose in the report dialog.
class ReportChoice {
  final ReportReason reason;
  final String note;
  final bool includeMessages;
  final bool alsoBlock;

  const ReportChoice({
    required this.reason,
    required this.note,
    required this.includeMessages,
    required this.alsoBlock,
  });
}

/// Asks why, and what to send, then reports [user] to the server's admin.
/// [recentMessages] is the end of the chat, attached only if the person ticks
/// the box that says so. Returns true if the report was sent.
Future<bool> reportUser(
  BuildContext context, {
  required BlockedUser user,
  required List<AttachedMessage> Function() recentMessages,
  ReportsApi api = const ServerReportsApi(),
  Future<String?> Function(BlockedUser user)? block,
  bool alreadyBlocked = false,
}) async {
  final choice = await showDialog<ReportChoice>(
    context: context,
    builder: (_) => ReportDialog(
      displayName: user.displayName,
      canAttach: recentMessages().isNotEmpty,
      canBlock: !alreadyBlocked,
    ),
  );
  if (choice == null || !context.mounted) return false;

  try {
    await api.send(
      userId: user.id,
      reason: choice.reason,
      note: choice.note,
      messages: choice.includeMessages ? recentMessages() : const [],
    );
  } catch (e) {
    if (context.mounted) {
      showSnack(
        context,
        ApiService.errorMessage(e, fallback: 'Couldn\'t send the report.'),
        isError: true,
      );
    }
    return false;
  }

  String? blockError;
  if (choice.alsoBlock) {
    blockError = await (block ?? BlockedUsers.instance.block)(user);
  }
  if (context.mounted) {
    showSnack(
      context,
      blockError != null
          ? 'Report sent, but ${user.displayName} wasn\'t blocked: $blockError'
          : choice.alsoBlock
          ? 'Report sent. ${user.displayName} is blocked.'
          : 'Report sent. Thank you.',
      isError: blockError != null,
    );
  }
  return true;
}

class ReportDialog extends StatefulWidget {
  final String displayName;

  /// Whether the chat has messages that could be attached.
  final bool canAttach;

  /// False if they are blocked already.
  final bool canBlock;

  const ReportDialog({
    super.key,
    required this.displayName,
    required this.canAttach,
    required this.canBlock,
  });

  @override
  State<ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends State<ReportDialog> {
  ReportReason? _reason;
  bool _attach = false;
  bool _block = false;
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Report ${widget.displayName}'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This goes to the person who runs this server. Messages are end-to-end '
            'encrypted, so they can\'t read the chat unless you send them some. '
            '${widget.displayName} isn\'t told.',
            style: context.text.bodyMedium,
          ),
          const SizedBox(height: Insets.md),
          for (final reason in ReportReason.values)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(reason.label),
              trailing: _reason == reason
                  ? Icon(
                      Icons.check_circle_rounded,
                      color: context.colors.primary,
                    )
                  : const Icon(Icons.radio_button_unchecked_rounded),
              selected: _reason == reason,
              onTap: () => setState(() => _reason = reason),
            ),
          const SizedBox(height: Insets.sm),
          TextField(
            controller: _note,
            maxLength: ReportLimits.note,
            maxLines: 3,
            minLines: 1,
            decoration: const InputDecoration(
              hintText: 'Add a note (optional)',
            ),
          ),
          if (widget.canAttach)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _attach,
              onChanged: (v) => setState(() => _attach = v ?? false),
              title: const Text('Include the last few messages'),
              subtitle: const Text(
                'These messages will be sent to the server admin as plain text.',
              ),
            ),
          if (widget.canBlock)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _block,
              onChanged: (v) => setState(() => _block = v ?? false),
              title: Text('Also block ${widget.displayName}'),
            ),
        ],
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _reason == null
              ? null
              : () => Navigator.pop(
                  context,
                  ReportChoice(
                    reason: _reason!,
                    note: _note.text.trim(),
                    includeMessages: _attach,
                    alsoBlock: _block,
                  ),
                ),
          child: const Text('Send report'),
        ),
      ],
    );
  }
}
