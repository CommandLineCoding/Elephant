import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class HelpAboutPage extends StatelessWidget {
  const HelpAboutPage({super.key});

  final String githubUrl = "https://github.com/commandlinecoding/elephant";

  Future<void> _launchGitHub() async {
    final Uri url = Uri.parse(githubUrl);
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      debugPrint('Could not launch $url');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Help & About'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        physics: const BouncingScrollPhysics(),
        children: [
          // --- HEADER SECTION ---
          const SizedBox(height: 20),
          Center(
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.lock_person_rounded,
                size: 64,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              'Elephant',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.onSurface,
                letterSpacing: 1.2,
              ),
            ),
          ),
          Center(
            child: Text(
              'Version 0.3.1 - Secure Messaging',
              style: TextStyle(
                fontSize: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 32),

          // --- ABOUT & PRIVACY SECTION ---
          _buildSectionHeader(context, 'Privacy & Security', Icons.shield),
          Card(
            elevation: 0,
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.4,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildFaqItem(
                    context,
                    'Are my messages private?',
                    'Yes. 1-on-1 chats use the Signal Protocol for true End-to-End Encryption (E2EE). Your private keys never leave your device, meaning the server cannot read your messages.',
                  ),
                  const Divider(),
                  _buildFaqItem(
                    context,
                    'Why do I see "Sent from another device"?',
                    'Because of forward secrecy, messages are locked cryptographically. If you uninstall the app or clear your local database, you lose the local keys needed to unlock old messages, ensuring past conversations remain secure even if your device is compromised.',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // --- KNOWN BUGS SECTION ---
          _buildSectionHeader(
            context,
            'Known Bugs & V0.3.1 Limitations',
            Icons.bug_report,
          ),
          Card(
            elevation: 0,
            color: theme.colorScheme.errorContainer.withValues(alpha: 0.3),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildBugItem(
                    context,
                    'Group Chats are not fully E2EE yet',
                    'Currently, 1-on-1 chats are fully encrypted using LibSignal. However, Group Chats currently use transport-level encryption (WSS/TLS) and temporary plaintext payloads. Full Signal "Sender Key" encryption for groups is planned for V2.',
                  ),
                  const SizedBox(height: 12),
                  _buildBugItem(
                    context,
                    'Empty Group Scroll Glitch',
                    'Opening a completely empty group chat for the first time may cause a minor visual glitch (RangeError) in the UI until the first message is sent.',
                  ),
                  const SizedBox(height: 12),
                  _buildBugItem(
                    context,
                    'Database Sync Overwrites',
                    'While heavy guards are in place, forcing app closes during heavy network syncs might occasionally drop offline read-receipts.',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // --- GITHUB & SUPPORT SECTION ---
          _buildSectionHeader(context, 'Support & Contribution', Icons.code),
          Card(
            elevation: 0,
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.4,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),
              leading: Icon(
                Icons.open_in_new,
                color: theme.colorScheme.primary,
              ),
              title: const Text('Report an Issue on GitHub'),
              subtitle: const Text(
                'Found a bug? Help us improve Elephant by opening an issue on our repository.',
              ),
              trailing: const Icon(Icons.arrow_forward_ios, size: 16),
              onTap: _launchGitHub,
            ),
          ),
          const SizedBox(height: 40),

          Center(
            child: Text(
              'Made with 🩵 by CommandLineCoding',
              style: TextStyle(
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.7,
                ),
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(
    BuildContext context,
    String title,
    IconData icon,
  ) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 12),
      child: Row(
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFaqItem(BuildContext context, String question, String answer) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            question,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 15,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            answer,
            style: TextStyle(
              fontSize: 14,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBugItem(BuildContext context, String title, String description) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2.0),
          child: Icon(Icons.circle, size: 8, color: theme.colorScheme.error),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                description,
                style: TextStyle(
                  fontSize: 13,
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
