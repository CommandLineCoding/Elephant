import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:mobile/controllers/auth_state.dart';
import 'package:mobile/controllers/chat/active_chat_controller.dart';
import 'package:mobile/controllers/chat/chat_connection_controller.dart';
import 'package:mobile/controllers/chat/group_details_controller.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/core/constants.dart';
import 'package:mobile/core/profile_limits.dart';
import 'package:mobile/core/username.dart';
import 'package:mobile/models/user.dart';
import 'package:mobile/pages/settings/signed_in_devices.dart';
import 'package:mobile/pages/settings/two_step_page.dart';
import 'package:mobile/providers/group_controller_provider.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/ui/avatar.dart';
import 'package:mobile/widgets/ui/components.dart';
import 'package:mobile/widgets/ui/feedback.dart';
import 'package:mobile/widgets/ui/surfaces.dart';
import 'package:provider/provider.dart';

/// Ends the session and returns to the sign-in screen. Encryption keys stay on
/// the device so the same account can sign back in without losing history.
Future<void> signOut(BuildContext context) async {
  final navigator = Navigator.of(context);
  context.read<ChatConnectionController>().disconnectWebSocket();
  context.read<GroupDetailsController>().clearCache();
  context.read<InboxController>().clearInbox();
  context.read<GroupController>().clearGroupData();
  final activeChat = context.read<ActiveChatController>();
  if (activeChat.currentChatUserId != null) {
    activeChat.closeChat(activeChat.currentChatUserId!);
  }
  await context.read<AuthState>().logout();
  navigator.popUntil((route) => route.isFirst);
}

/// Asks the user to type their username, deletes the account and signs out.
Future<void> _deleteAccount(BuildContext context, String username) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => _DeleteAccountDialog(username: username),
  );
  if (confirmed != true || !context.mounted) return;

  final error = await context.read<AuthState>().deleteAccount();
  if (!context.mounted) return;
  if (error != null) {
    showSnack(context, error);
    return;
  }
  await signOut(context);
}

/// What the person chose in [StatusDialog].
class StatusChoice {
  final String emoji;
  final String text;
  final StatusDuration duration;

  const StatusChoice(this.emoji, this.text, this.duration);

  /// Whether this clears the status.
  bool get isClear => emoji.isEmpty && text.isEmpty;
}

/// Set or clear the custom status: an emoji, a few words, and how long.
@visibleForTesting
class StatusDialog extends StatefulWidget {
  final String emoji;
  final String text;

  const StatusDialog({super.key, this.emoji = '', this.text = ''});

  @override
  State<StatusDialog> createState() => StatusDialogState();
}

@visibleForTesting
class StatusDialogState extends State<StatusDialog> {
  late final TextEditingController _emoji = TextEditingController(
    text: widget.emoji,
  );
  late final TextEditingController _text = TextEditingController(
    text: widget.text,
  );
  StatusDuration _duration = StatusDuration.never;

  static const _suggestions = ['🚴', '🎧', '📚', '🌴', '🍽️', '💼'];

  bool get _hasAny =>
      _emoji.text.trim().isNotEmpty || _text.text.trim().isNotEmpty;

  @override
  void dispose() {
    _emoji.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Status'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Shown under your name in chats and on your profile. Anyone who '
            'can look you up can see it.',
            style: context.text.bodyMedium,
          ),
          const SizedBox(height: Insets.lg),
          Row(
            children: [
              SizedBox(
                width: 64,
                child: TextField(
                  controller: _emoji,
                  textAlign: TextAlign.center,
                  maxLength: 8,
                  buildCounter:
                      (
                        _, {
                        required currentLength,
                        required isFocused,
                        maxLength,
                      }) => null,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(hintText: '🙂'),
                ),
              ),
              const SizedBox(width: Insets.md),
              Expanded(
                child: TextField(
                  controller: _text,
                  maxLength: profileStatusMax,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(hintText: 'What\'s up?'),
                ),
              ),
            ],
          ),
          Wrap(
            spacing: Insets.sm,
            children: [
              for (final e in _suggestions)
                ActionChip(
                  label: Text(e),
                  onPressed: () => setState(() => _emoji.text = e),
                ),
            ],
          ),
          const SizedBox(height: Insets.lg),
          Text('Clear after', style: context.text.labelLarge),
          for (final d in StatusDuration.values)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(d.label),
              trailing: _duration == d
                  ? Icon(
                      Icons.check_circle_rounded,
                      color: context.colors.primary,
                    )
                  : const Icon(Icons.radio_button_unchecked_rounded),
              onTap: () => setState(() => _duration = d),
            ),
        ],
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      actions: [
        if (widget.emoji.isNotEmpty || widget.text.isNotEmpty)
          TextButton(
            onPressed: () => Navigator.pop(
              context,
              const StatusChoice('', '', StatusDuration.never),
            ),
            child: const Text('Clear'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _hasAny
              ? () => Navigator.pop(
                  context,
                  StatusChoice(
                    _emoji.text.trim(),
                    _text.text.trim(),
                    _duration,
                  ),
                )
              : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Asks for the new username, and says what changing it means first.
@visibleForTesting
class ChangeUsernameDialog extends StatefulWidget {
  final String current;

  const ChangeUsernameDialog({super.key, required this.current});

  @override
  State<ChangeUsernameDialog> createState() => ChangeUsernameDialogState();
}

@visibleForTesting
class ChangeUsernameDialogState extends State<ChangeUsernameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: usernamePrefix(widget.current),
  );

  bool _edited = false;

  String? get _problem {
    final text = _controller.text;
    final problem = usernamePrefixProblem(text);
    if (problem != null) return problem;
    if (text.trim().toLowerCase() == usernamePrefix(widget.current)) {
      return 'That is already your username.';
    }
    return null;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final problem = _problem;
    return AlertDialog(
      title: const Text('Change username'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'You will sign in with your new username from now on, and the old '
            'one stops working. Links and QR codes with the old one stop '
            'finding you. Your chats are not affected.\n\n'
            'A new four digit number is added after the dot, and you can '
            'change it again after 30 days.',
            style: context.text.bodyMedium,
          ),
          const SizedBox(height: Insets.lg),
          TextField(
            controller: _controller,
            autofocus: true,
            autocorrect: false,
            maxLength: usernamePrefixMax,
            onChanged: (_) => setState(() => _edited = true),
            decoration: InputDecoration(
              prefixText: '@',
              suffixText: '.####',
              helperText: 'Letters and numbers only',
              // Not before they have typed: it starts as the current name.
              errorText: _edited && _controller.text.isNotEmpty
                  ? problem
                  : null,
            ),
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
          onPressed: problem == null
              ? () => Navigator.pop(context, _controller.text.trim())
              : null,
          child: const Text('Change'),
        ),
      ],
    );
  }
}

class _DeleteAccountDialog extends StatefulWidget {
  final String username;

  const _DeleteAccountDialog({required this.username});

  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  final TextEditingController _controller = TextEditingController();

  bool get _matches => _controller.text.trim() == widget.username;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Delete account?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'This permanently deletes your account, your messages and your '
            'group memberships from the server, and erases them from this '
            'device. It can\'t be undone.',
          ),
          const SizedBox(height: Insets.lg),
          Text('Type ${widget.username} to confirm.'),
          const SizedBox(height: Insets.sm),
          TextField(
            controller: _controller,
            autocorrect: false,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(hintText: widget.username),
          ),
        ],
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: context.colors.error,
            foregroundColor: context.colors.onError,
            minimumSize: const Size(88, 44),
          ),
          onPressed: _matches ? () => Navigator.pop(context, true) : null,
          child: const Text('Delete'),
        ),
      ],
    );
  }
}

class AccountsSettings extends StatelessWidget {
  const AccountsSettings({super.key});

  void _copy(BuildContext context, String value, String label) {
    Clipboard.setData(ClipboardData(text: value));
    showSnack(context, '$label copied');
  }

  Future<void> _editDisplayName(BuildContext context, String current) async {
    final name = await promptText(
      context,
      title: 'Display name',
      message: 'This is how others see you.',
      initialValue: current,
      hint: 'Your name',
      maxLength: 100,
    );
    if (name == null || name == current || !context.mounted) return;
    final error = await context.read<AuthState>().updateDisplayName(name);
    if (context.mounted) {
      showSnack(
        context,
        error ?? 'Display name updated',
        isError: error != null,
      );
    }
  }

  String _statusEnds(UserModel user) {
    final ends = user.statusExpiresAt;
    return ends == null
        ? 'Status · until you change it'
        : 'Status · until ${DateFormat.MMMd().add_jm().format(ends)}';
  }

  String _changeSubtitle(UserModel? user) {
    final wait = nextUsernameChange(user?.usernameChangedAt, DateTime.now());
    return wait == null
        ? 'Once every 30 days. You get a new number after the dot.'
        : 'You can change it again after ${DateFormat.yMMMd().format(wait)}.';
  }

  Future<void> _editAbout(BuildContext context, UserModel user) async {
    final text = await promptText(
      context,
      title: 'About',
      message:
          'A few words about you. Anyone who can look you up can read this.',
      initialValue: user.bio,
      hint: 'About you',
      maxLength: profileBioMax,
    );
    if (text == null || text.trim() == user.bio || !context.mounted) return;
    final error = await context.read<AuthState>().updateProfile(bio: text);
    if (context.mounted) {
      showSnack(context, error ?? 'About updated', isError: error != null);
    }
  }

  Future<void> _editStatus(BuildContext context, UserModel user) async {
    final result = await showDialog<StatusChoice>(
      context: context,
      builder: (_) => StatusDialog(
        emoji: user.hasStatus() ? user.statusEmoji : '',
        text: user.hasStatus() ? user.statusText : '',
      ),
    );
    if (result == null || !context.mounted) return;
    final error = await context.read<AuthState>().updateProfile(
      statusEmoji: result.emoji,
      statusText: result.text,
      statusExpiresIn: result.duration.from(DateTime.now()),
    );
    if (context.mounted) {
      showSnack(
        context,
        error ?? (result.isClear ? 'Status cleared' : 'Status set'),
        isError: error != null,
      );
    }
  }

  Future<void> _changeUsername(BuildContext context, UserModel user) async {
    final wait = nextUsernameChange(user.usernameChangedAt, DateTime.now());
    if (wait != null) {
      showSnack(
        context,
        'You can change your username again after '
        '${DateFormat.yMMMd().format(wait)}.',
      );
      return;
    }
    final prefix = await showDialog<String>(
      context: context,
      builder: (_) => ChangeUsernameDialog(current: user.username),
    );
    if (prefix == null || !context.mounted) return;
    final error = await context.read<AuthState>().changeUsername(prefix);
    if (!context.mounted) return;
    if (error != null) {
      showSnack(context, error, isError: true);
      return;
    }
    final now = context.read<AuthState>().currentUser?.username;
    showSnack(context, 'You are now @$now. Sign in with it from now on.');
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthState>().currentUser;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: const ElephantAppBar(title: Text('Account')),
      body: ScreenBackground(
        child: ListView(
          padding: EdgeInsets.only(
            top: MediaQuery.paddingOf(context).top + kToolbarHeight + Insets.xl,
            bottom: Insets.xxl + MediaQuery.paddingOf(context).bottom,
          ),
          children: [
            Center(
              child: Hero(
                tag: 'me-avatar',
                child: ElephantAvatar(
                  name: user?.displayName ?? '?',
                  seed: user?.id ?? '',
                  size: 104,
                ),
              ),
            ),
            const SizedBox(height: Insets.lg),
            Text(
              user?.displayName ?? '',
              textAlign: TextAlign.center,
              style: context.text.headlineMedium?.copyWith(fontSize: 26),
            ),
            if (user?.createdAt != null)
              Text(
                'Member since ${DateFormat.yMMMM().format(user!.createdAt!)}',
                textAlign: TextAlign.center,
                style: context.text.bodyMedium?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            const SectionLabel('Profile'),
            Section(
              children: [
                ElephantTile(
                  icon: Icons.alternate_email_rounded,
                  title: user != null ? '@${user.username}' : '—',
                  subtitle:
                      'Your username. Use it to sign in; others use it to find you.',
                  trailing: const Icon(Icons.copy_rounded, size: 18),
                  onTap: user == null
                      ? null
                      : () => _copy(context, user.username, 'Username'),
                ),
                ElephantTile(
                  icon: Icons.drive_file_rename_outline_rounded,
                  title: 'Change username',
                  subtitle: _changeSubtitle(user),
                  onTap: user == null
                      ? null
                      : () => _changeUsername(context, user),
                ),
                ElephantTile(
                  icon: Icons.info_outline_rounded,
                  title: user == null || user.bio.isEmpty
                      ? 'Add an about text'
                      : user.bio,
                  subtitle: 'About · anyone who can look you up can read it',
                  onTap: user == null ? null : () => _editAbout(context, user),
                ),
                ElephantTile(
                  icon: Icons.mood_rounded,
                  title: user?.statusLine() ?? 'Set a status',
                  subtitle: user != null && user.hasStatus()
                      ? _statusEnds(user)
                      : 'Shown under your name in chats',
                  onTap: user == null ? null : () => _editStatus(context, user),
                ),
                ElephantTile(
                  icon: Icons.badge_outlined,
                  title: user?.displayName ?? '—',
                  subtitle: 'Display name',
                  trailing: Icon(
                    Icons.edit_outlined,
                    size: 20,
                    color: context.colors.onSurfaceVariant,
                  ),
                  onTap: user == null
                      ? null
                      : () => _editDisplayName(context, user.displayName),
                ),
                if (user?.email != null)
                  ElephantTile(
                    icon: Icons.mail_outline_rounded,
                    title: user!.email!,
                    subtitle: 'Email from Google or GitHub sign-in',
                    showChevron: false,
                  ),
                ElephantTile(
                  icon: Icons.fingerprint_rounded,
                  title: 'User ID',
                  subtitle: user?.id ?? '—',
                  trailing: const Icon(Icons.copy_rounded, size: 18),
                  onTap: user == null
                      ? null
                      : () => _copy(context, user.id, 'User ID'),
                ),
              ],
            ),
            const SectionLabel('Security'),
            Section(
              children: [
                // Only for accounts that sign in with a password: an account
                // made with Google or GitHub has none to protect.
                if (user?.email == null)
                  ElephantTile(
                    icon: Icons.shield_outlined,
                    title: 'Two-step sign-in',
                    subtitle: 'Ask for a code from an authenticator app',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const TwoStepSignInPage(),
                      ),
                    ),
                  ),
                ElephantTile(
                  icon: Icons.devices_rounded,
                  title: 'Signed-in devices',
                  subtitle: 'See where you\'re signed in, and sign devices out',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const SignedInDevicesPage(),
                    ),
                  ),
                ),
              ],
            ),
            const SectionLabel('Server'),
            Section(
              children: [
                ElephantTile(
                  icon: Icons.dns_outlined,
                  title: Env.isDefaultServer ? 'Elephant Cloud' : 'Self-hosted',
                  subtitle:
                      '${Env.host}:${Env.port}\nSign out to switch servers.',
                  showChevron: false,
                ),
              ],
            ),
            const SizedBox(height: Insets.xl),
            Section(
              children: [
                ElephantTile(
                  icon: Icons.logout_rounded,
                  title: 'Sign out',
                  destructive: true,
                  showChevron: false,
                  onTap: () async {
                    final confirmed = await confirmAction(
                      context,
                      title: 'Sign out?',
                      message:
                          'Your messages and encryption keys stay on this device for when you sign back in. Signing in with a different account here erases them.',
                      confirmLabel: 'Sign out',
                      destructive: true,
                    );
                    if (confirmed && context.mounted) await signOut(context);
                  },
                ),
                ElephantTile(
                  icon: Icons.delete_forever_rounded,
                  title: 'Delete account',
                  destructive: true,
                  showChevron: false,
                  onTap: user == null
                      ? null
                      : () => _deleteAccount(context, user.username),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
