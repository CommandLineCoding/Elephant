import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:mobile/controllers/auth_state.dart';
import 'package:mobile/controllers/chat/active_chat_controller.dart';
import 'package:mobile/controllers/chat/chat_connection_controller.dart';
import 'package:mobile/controllers/chat/group_details_controller.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/core/constants.dart';
import 'package:mobile/providers/group_controller_provider.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/ui/avatar.dart';
import 'package:mobile/widgets/ui/components.dart';
import 'package:mobile/widgets/ui/feedback.dart';
import 'package:mobile/widgets/ui/glass.dart';
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

class AccountsSettings extends StatelessWidget {
  const AccountsSettings({super.key});

  void _copy(BuildContext context, String value, String label) {
    Clipboard.setData(ClipboardData(text: value));
    showSnack(context, '$label copied');
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthState>().currentUser;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: const GlassAppBar(title: Text('Account')),
      body: AmbientBackground(
        intensity: 0.7,
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
            GlassSection(
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
                  icon: Icons.badge_outlined,
                  title: user?.displayName ?? '—',
                  subtitle: 'Display name',
                  showChevron: false,
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
            const SectionLabel('Server'),
            GlassSection(
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
            GlassSection(
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
                          'Your messages and encryption keys stay on this device for when you sign back in.',
                      confirmLabel: 'Sign out',
                      destructive: true,
                    );
                    if (confirmed && context.mounted) await signOut(context);
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
