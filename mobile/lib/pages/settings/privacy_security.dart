import 'package:flutter/material.dart';
import 'package:mobile/core/link_preview.dart';
import 'package:mobile/pages/settings/blocked_users.dart';
import 'package:mobile/services/api_services.dart';
import 'package:mobile/services/app_lock.dart';
import 'package:mobile/services/screen_security.dart';
import 'package:mobile/services/signal_service.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/ui/components.dart';
import 'package:mobile/widgets/ui/feedback.dart';
import 'package:mobile/widgets/ui/surfaces.dart';

class PrivacySecuritySettingsPage extends StatefulWidget {
  const PrivacySecuritySettingsPage({super.key});

  @override
  State<PrivacySecuritySettingsPage> createState() =>
      _PrivacySecuritySettingsPageState();
}

class _PrivacySecuritySettingsPageState
    extends State<PrivacySecuritySettingsPage> {
  bool _busy = false;
  bool _linkPreviews = true;

  @override
  void initState() {
    super.initState();
    LinkPreviewPrefs.isEnabled().then((on) {
      if (mounted) setState(() => _linkPreviews = on);
    });
  }

  Future<void> _setLinkPreviews(bool on) async {
    setState(() => _linkPreviews = on);
    await LinkPreviewPrefs.setEnabled(on);
  }

  Future<void> _setAppLock(bool on) async {
    final error = await AppLock.instance.setEnabled(on);
    if (error != null && mounted) showSnack(context, error, isError: true);
  }

  Future<void> _chooseLockAfter() async {
    final chosen = await showDialog<Duration>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Lock after'),
        children: [
          for (final after in AppLock.timeouts)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, after),
              child: Row(
                children: [
                  Expanded(child: Text(lockAfterLabel(after))),
                  if (after == AppLock.instance.lockAfter)
                    const Icon(Icons.check_rounded),
                ],
              ),
            ),
        ],
      ),
    );
    if (chosen != null) await AppLock.instance.setLockAfter(chosen);
  }

  Future<void> _resetSessions() async {
    final confirmed = await confirmAction(
      context,
      title: 'Reset all secure sessions?',
      message:
          'Deletes every encrypted session on this device. New sessions are created automatically '
          'the next time you message each contact. Your chat history stays.',
      confirmLabel: 'Reset',
    );
    if (!confirmed || !mounted) return;
    await SignalService().clearAllSessions();
    if (mounted) showSnack(context, 'All secure sessions were reset');
  }

  Future<void> _resetKeys() async {
    final password = await promptText(
      context,
      title: 'Reset encryption keys',
      message:
          'This replaces your identity key on the server and this device. Every contact will see a new '
          'safety number and needs to verify you again. Enter your password to continue.',
      hint: 'Password',
      obscure: true,
      confirmLabel: 'Reset keys',
    );
    if (password == null || password.isEmpty || !mounted) return;

    setState(() => _busy = true);
    try {
      await SignalService().resetAllKeys(password);
      if (mounted) {
        showSnack(context, 'New encryption keys created and published');
      }
    } catch (e) {
      if (mounted) {
        showSnack(
          context,
          ApiService.errorMessage(e, fallback: 'Couldn\'t reset your keys.'),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: ElephantAppBar(
        title: const Text('Privacy & security'),
        actions: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
      ),
      body: ScreenBackground(
        child: ListView(
          padding: EdgeInsets.only(
            top: MediaQuery.paddingOf(context).top + kToolbarHeight + Insets.lg,
            bottom: Insets.xxl + MediaQuery.paddingOf(context).bottom,
          ),
          children: [
            PageIntro(
              icon: Icons.lock_outline_rounded,
              title: 'Your keys never leave this device',
              body:
                  'Direct messages use the Signal Protocol. The server only stores your public keys '
                  'and encrypted text, so it can\'t read your direct chats.',
            ),
            const SectionLabel('What\'s protected'),
            Section(
              children: [
                ElephantTile(
                  icon: Icons.lock_rounded,
                  iconColor: context.tokens.success,
                  title: 'Direct messages',
                  subtitle: 'End-to-end encrypted',
                  showChevron: false,
                ),
                ElephantTile(
                  icon: Icons.lock_open_rounded,
                  iconColor: context.tokens.warning,
                  title: 'Group messages',
                  subtitle:
                      'Encrypted in transit only. End-to-end encryption for groups is coming.',
                  showChevron: false,
                ),
                ElephantTile(
                  icon: Icons.storage_rounded,
                  iconColor: context.tokens.success,
                  title: 'Messages on this device',
                  subtitle: 'Stored in an encrypted database',
                  showChevron: false,
                ),
              ],
            ),
            const SectionLabel('Links'),
            Section(
              children: [
                ElephantTile(
                  icon: Icons.link_rounded,
                  title: 'Link previews',
                  subtitle: _linkPreviews
                      ? 'When you paste a link, Elephant looks it up to show a preview. '
                            'The website sees your address; your contact\'s phone never visits it.'
                      : 'Links are sent without a preview. Nothing is looked up.',
                  showChevron: false,
                  trailing: Switch(
                    value: _linkPreviews,
                    onChanged: _setLinkPreviews,
                  ),
                ),
              ],
            ),
            const SectionLabel('On this phone'),
            Section(
              children: [
                ListenableBuilder(
                  listenable: AppLock.instance,
                  builder: (context, _) => ElephantTile(
                    icon: Icons.fingerprint_rounded,
                    title: 'App lock',
                    subtitle: AppLock.instance.enabled
                        ? 'Elephant asks for your fingerprint, face or screen '
                              'lock to open.'
                        : 'Ask for your fingerprint, face or screen lock '
                              'to open Elephant.',
                    showChevron: false,
                    trailing: Switch(
                      value: AppLock.instance.enabled,
                      onChanged: _setAppLock,
                    ),
                  ),
                ),
                ListenableBuilder(
                  listenable: AppLock.instance,
                  builder: (context, _) => AppLock.instance.enabled
                      ? ElephantTile(
                          icon: Icons.timer_outlined,
                          title: 'Lock after',
                          subtitle: lockAfterLabel(AppLock.instance.lockAfter),
                          onTap: _chooseLockAfter,
                        )
                      : const SizedBox.shrink(),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: ScreenSecurity.screenSecure,
                  builder: (context, on, _) => ElephantTile(
                    icon: Icons.screen_lock_portrait_rounded,
                    title: 'Screen security',
                    subtitle: on
                        ? 'Screenshots and screen recordings are blocked, and the '
                              'app is hidden in the recent-apps list.'
                        : 'Allow screenshots and show the app in the recent-apps list.',
                    showChevron: false,
                    trailing: Switch(
                      value: on,
                      onChanged: ScreenSecurity.setScreenSecure,
                    ),
                  ),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: ScreenSecurity.incognitoKeyboard,
                  builder: (context, on, _) => ElephantTile(
                    icon: Icons.keyboard_alt_outlined,
                    title: 'Incognito keyboard',
                    subtitle: on
                        ? 'Your keyboard is asked not to learn from what you type '
                              'in the message box.'
                        : 'Your keyboard may learn words you type in the message box.',
                    showChevron: false,
                    trailing: Switch(
                      value: on,
                      onChanged: ScreenSecurity.setIncognitoKeyboard,
                    ),
                  ),
                ),
              ],
            ),
            const SectionLabel('People'),
            Section(
              children: [
                ElephantTile(
                  icon: Icons.block_rounded,
                  title: 'Blocked users',
                  subtitle: 'People who can\'t send you direct messages',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const BlockedUsersPage()),
                  ),
                ),
              ],
            ),
            const SectionLabel('Troubleshooting'),
            Section(
              children: [
                ElephantTile(
                  icon: Icons.restart_alt_rounded,
                  iconColor: context.tokens.warning,
                  title: 'Reset all secure sessions',
                  subtitle:
                      'Fixes messages that won\'t decrypt across many chats.',
                  onTap: _busy ? null : _resetSessions,
                ),
                ElephantTile(
                  icon: Icons.key_off_rounded,
                  title: 'Reset encryption keys',
                  subtitle:
                      'Create a new identity. Contacts will need to verify you again.',
                  destructive: true,
                  onTap: _busy ? null : _resetKeys,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Insets.page + 4,
                Insets.lg,
                Insets.page + 4,
                0,
              ),
              child: Text(
                'To check a contact\'s identity, open their chat, tap their name, then Verify safety number.',
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// How [AppLock.lockAfter] reads in settings.
String lockAfterLabel(Duration after) {
  if (after == Duration.zero) return 'Immediately';
  final minutes = after.inMinutes;
  return minutes == 1 ? 'After 1 minute' : 'After $minutes minutes';
}
