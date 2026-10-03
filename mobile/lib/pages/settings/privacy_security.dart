import 'package:flutter/material.dart';
import 'package:mobile/services/api_services.dart';
import 'package:mobile/services/signal_service.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/ui/components.dart';
import 'package:mobile/widgets/ui/feedback.dart';
import 'package:mobile/widgets/ui/glass.dart';

class PrivacySecuritySettingsPage extends StatefulWidget {
  const PrivacySecuritySettingsPage({super.key});

  @override
  State<PrivacySecuritySettingsPage> createState() =>
      _PrivacySecuritySettingsPageState();
}

class _PrivacySecuritySettingsPageState
    extends State<PrivacySecuritySettingsPage> {
  bool _busy = false;

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
      appBar: GlassAppBar(
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
      body: AmbientBackground(
        intensity: 0.7,
        child: ListView(
          padding: EdgeInsets.only(
            top: MediaQuery.paddingOf(context).top + kToolbarHeight + Insets.lg,
            bottom: Insets.xxl + MediaQuery.paddingOf(context).bottom,
          ),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.page),
              child: GlassSurface(
                borderRadius: BorderRadius.circular(Radii.xl),
                padding: const EdgeInsets.all(Insets.xl),
                child: Column(
                  children: [
                    AccentGradientBox(
                      shape: BoxShape.circle,
                      padding: const EdgeInsets.all(16),
                      child: Icon(
                        Icons.lock_rounded,
                        size: 34,
                        color: context.glass.onAccent,
                      ),
                    ),
                    const SizedBox(height: Insets.lg),
                    Text(
                      'Your keys never leave this device',
                      style: context.text.titleLarge,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: Insets.sm),
                    Text(
                      'Direct messages use the Signal Protocol. The server only stores your public keys '
                      'and encrypted text, so it can\'t read your direct chats.',
                      textAlign: TextAlign.center,
                      style: context.text.bodyMedium?.copyWith(
                        color: context.colors.onSurfaceVariant,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SectionLabel('What\'s protected'),
            GlassSection(
              children: [
                ElephantTile(
                  icon: Icons.lock_rounded,
                  iconColor: context.glass.success,
                  title: 'Direct messages',
                  subtitle: 'End-to-end encrypted',
                  showChevron: false,
                ),
                ElephantTile(
                  icon: Icons.lock_open_rounded,
                  iconColor: context.glass.warning,
                  title: 'Group messages',
                  subtitle:
                      'Encrypted in transit only. End-to-end encryption for groups is coming.',
                  showChevron: false,
                ),
                ElephantTile(
                  icon: Icons.storage_rounded,
                  iconColor: context.glass.success,
                  title: 'Messages on this device',
                  subtitle: 'Stored in an encrypted database',
                  showChevron: false,
                ),
              ],
            ),
            const SectionLabel('Troubleshooting'),
            GlassSection(
              children: [
                ElephantTile(
                  icon: Icons.restart_alt_rounded,
                  iconColor: context.glass.warning,
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
