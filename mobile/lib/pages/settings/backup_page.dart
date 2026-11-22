import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile/controllers/auth_state.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/core/backup_codec.dart';
import 'package:mobile/services/backup.dart';
import 'package:mobile/services/backup_files.dart';
import 'package:mobile/services/broadcast_lists.dart';
import 'package:mobile/services/calls/call_log.dart';
import 'package:mobile/services/chat_folders.dart';
import 'package:mobile/services/nicknames.dart';
import 'package:mobile/services/starred_messages.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/ui/feedback.dart';
import 'package:mobile/widgets/ui/surfaces.dart';
import 'package:provider/provider.dart';

/// Makes the screens read what a restore put in the database.
Future<void> reloadAfterRestore(BuildContext context) async {
  final inbox = context.read<InboxController>();
  Nicknames.instance.reset();
  ChatFolders.instance.reset();
  BroadcastLists.instance.reset();
  StarredMessages.instance.clear();
  CallLog.instance.clear();
  inbox.inbox = [];
  await Future.wait([
    Nicknames.instance.load(),
    ChatFolders.instance.load(),
    BroadcastLists.instance.load(),
    StarredMessages.instance.load(),
    inbox.loadPrefs(),
    inbox.loadInbox(),
  ]);
}

/// Save the chats to an encrypted file, or put them back from one.
class BackupPage extends StatefulWidget {
  final BackupService? service;
  final BackupFiles files;

  /// Runs after a restore, to reload what the screens show. The app's own
  /// is [reloadAfterRestore].
  final Future<void> Function(BuildContext context) onRestored;

  const BackupPage({
    super.key,
    this.service,
    this.files = const PickerBackupFiles(),
    this.onRestored = reloadAfterRestore,
  });

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  late final BackupService _service = widget.service ?? BackupService();
  bool _busy = false;

  String? get _userId => context.read<AuthState>().currentUser?.id;

  Future<void> _backUp() async {
    final userId = _userId;
    if (userId == null) return;
    final passphrase = BackupCodec.generatePassphrase();
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PassphraseDialog(passphrase: passphrase),
    );
    if (saved != true || !mounted) return;

    setState(() => _busy = true);
    try {
      final bytes = await _service.create(
        userId: userId,
        passphrase: passphrase,
      );
      final done = await widget.files.save(
        backupFileName(DateTime.now()),
        bytes,
      );
      if (mounted && done) showSnack(context, 'Backup saved');
    } catch (e) {
      debugPrint("Backup failed: $e");
      if (mounted) {
        showSnack(context, 'Couldn\'t make the backup.', isError: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    final userId = _userId;
    if (userId == null) return;
    final file = await widget.files.pick();
    if (file == null || !mounted) return;

    String? error;
    while (mounted) {
      final passphrase = await showDialog<String>(
        context: context,
        builder: (_) => _RestoreDialog(error: error),
      );
      if (passphrase == null || !mounted) return;

      setState(() => _busy = true);
      try {
        final summary = await _service.restore(
          file,
          passphrase,
          userId: userId,
        );
        if (!mounted) return;
        await widget.onRestored(context);
        if (mounted) {
          final n = summary.messages;
          showSnack(
            context,
            'Restored $n ${n == 1 ? 'message' : 'messages'} in '
            '${summary.chats} ${summary.chats == 1 ? 'chat' : 'chats'}',
          );
        }
        return;
      } on BackupException catch (e) {
        // A wrong passphrase can be tried again; the rest can't be helped.
        if (e.problem == BackupProblem.wrongPassphrase) {
          error = e.message;
        } else {
          if (mounted) showSnack(context, e.message, isError: true);
          return;
        }
      } catch (e) {
        debugPrint("Restore failed: $e");
        if (mounted) {
          showSnack(
            context,
            'Couldn\'t restore the backup. Nothing was changed.',
            isError: true,
          );
        }
        return;
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top + kToolbarHeight + Insets.lg;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: const ElephantAppBar(title: Text('Chat backup')),
      body: ScreenBackground(
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            Insets.page,
            top,
            Insets.page,
            Insets.xxl + MediaQuery.paddingOf(context).bottom,
          ),
          children: [
            Text(
              'Your chats live only on this phone',
              style: context.text.headlineSmall,
            ),
            const SizedBox(height: Insets.sm),
            Text(
              'A lost or reset phone loses them, and the server can\'t help: '
              'it can\'t read them. A backup is one file with your messages, '
              'chats and call history, locked with a 30-digit passphrase the '
              'app makes for you. Keep the file wherever you like (this '
              'phone, a USB drive, a cloud app) and the passphrase somewhere '
              'safe. Without the passphrase nobody can open it, and we can\'t '
              'recover it.',
              style: context.text.bodyMedium?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Insets.lg),
            Text(
              'Your encryption keys are not in it. After restoring on a new '
              'phone you start with new keys, so your contacts will see a '
              'changed safety number, and messages sent to your old phone '
              'before then can\'t be read.',
              style: context.text.bodyMedium?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Insets.xl),
            if (_busy)
              const Center(child: CircularProgressIndicator())
            else ...[
              FilledButton.icon(
                onPressed: _backUp,
                icon: const Icon(Icons.save_alt_rounded),
                label: const Text('Back up now'),
              ),
              const SizedBox(height: Insets.md),
              OutlinedButton.icon(
                onPressed: _restore,
                icon: const Icon(Icons.restore_rounded),
                label: const Text('Restore from a backup'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// ["11111 22222 33333 44444 55555 66666"] as two lines of three groups.
String _inTwoLines(String passphrase) {
  final groups = passphrase.split(' ');
  return '${groups.take(3).join(' ')}\n${groups.skip(3).join(' ')}';
}

/// Shows the passphrase once. The backup is only made after the person says
/// they have kept it.
class _PassphraseDialog extends StatefulWidget {
  final String passphrase;

  const _PassphraseDialog({required this.passphrase});

  @override
  State<_PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<_PassphraseDialog> {
  bool _kept = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Your backup passphrase'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'You need it to restore this backup, and it is shown only now. '
            'Write it down or put it in a password manager.',
            style: context.text.bodyMedium,
          ),
          const SizedBox(height: Insets.lg),
          Center(
            child: SelectableText(
              _inTwoLines(widget.passphrase),
              textAlign: TextAlign.center,
              style: context.text.titleLarge?.copyWith(
                fontFamily: 'monospace',
                letterSpacing: 1.5,
              ),
            ),
          ),
          const SizedBox(height: Insets.sm),
          Align(
            alignment: Alignment.center,
            child: TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: widget.passphrase));
                showSnack(context, 'Copied');
              },
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: const Text('Copy'),
            ),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _kept,
            onChanged: (v) => setState(() => _kept = v ?? false),
            title: const Text('I have kept it somewhere safe'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _kept ? () => Navigator.pop(context, true) : null,
          child: const Text('Choose where to save'),
        ),
      ],
    );
  }
}

class _RestoreDialog extends StatefulWidget {
  final String? error;

  const _RestoreDialog({this.error});

  @override
  State<_RestoreDialog> createState() => _RestoreDialogState();
}

class _RestoreDialogState extends State<_RestoreDialog> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Restore this backup'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Enter the 30-digit passphrase. Restoring replaces the chats on '
            'this phone with the ones in the backup.',
            style: context.text.bodyMedium,
          ),
          const SizedBox(height: Insets.lg),
          TextField(
            controller: _text,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9 -]')),
            ],
            onChanged: (_) => setState(() {}),
            onSubmitted: (v) => Navigator.pop(context, v),
            decoration: InputDecoration(
              hintText: '12345 67890 …',
              errorText: widget.error,
              errorMaxLines: 3,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: BackupCodec.normalize(_text.text).isEmpty
              ? null
              : () => Navigator.pop(context, _text.text),
          child: const Text('Restore'),
        ),
      ],
    );
  }
}
