import 'package:flutter/material.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/ui/components.dart';
import 'package:mobile/widgets/ui/glass.dart';
import 'package:url_launcher/url_launcher.dart';

class HelpAboutPage extends StatelessWidget {
  const HelpAboutPage({super.key});

  static const String appVersion = '0.3.1';
  static const String githubUrl =
      'https://github.com/commandlinecoding/elephant';

  Future<void> _open(String url) async {
    final uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      debugPrint('Could not launch $url');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: const GlassAppBar(title: Text('Help & about')),
      body: AmbientBackground(
        intensity: 0.8,
        child: ListView(
          padding: EdgeInsets.only(
            top: MediaQuery.paddingOf(context).top + kToolbarHeight + Insets.xl,
            bottom: Insets.xxl + MediaQuery.paddingOf(context).bottom,
          ),
          children: [
            Center(
              child: Container(
                width: 96,
                height: 96,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: context.glass.glassStrongFill,
                  border: Border.all(color: context.glass.glassBorder),
                  boxShadow: [
                    BoxShadow(
                      color: context.colors.primary.withValues(alpha: 0.3),
                      blurRadius: 36,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: Image.asset('assets/launcher/elephant.png'),
              ),
            ),
            const SizedBox(height: Insets.lg),
            Text(
              'Elephant',
              textAlign: TextAlign.center,
              style: context.text.headlineMedium,
            ),
            Text(
              'Version $appVersion · Open source, AGPL-3.0',
              textAlign: TextAlign.center,
              style: context.text.bodyMedium?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
            const SectionLabel('Common questions'),
            const GlassSection(
              children: [
                _Faq(
                  question: 'Who can read my messages?',
                  answer:
                      'Direct messages are end-to-end encrypted with the Signal Protocol: only you and the '
                      'person you\'re talking to can read them. Group messages are encrypted in transit, but '
                      'the server can read them for now.',
                ),
                _Faq(
                  question:
                      'Why do some messages say "Sent from another device"?',
                  answer:
                      'Your sent messages are encrypted for the recipient, so only the copy saved on the '
                      'device you sent them from can be read. After reinstalling, older sent messages can\'t '
                      'be recovered. That\'s forward secrecy at work.',
                ),
                _Faq(
                  question: 'A message says it can\'t be decrypted. What now?',
                  answer:
                      'Usually the other person reinstalled the app. Open the chat, tap their name, and choose '
                      'Reset secure session. Then verify their new safety number.',
                ),
                _Faq(
                  question: 'Can I edit a message?',
                  answer:
                      'Yes. Long-press your message within 15 minutes of sending it and tap Edit. The other '
                      'person sees the change the next time their chat refreshes.',
                ),
                _Faq(
                  question: 'Can I use my own server?',
                  answer:
                      'Yes. Sign out, then tap the server chip on the sign-in screen and enter your host and '
                      'port. Setup instructions are in the GitHub repository.',
                ),
              ],
            ),
            const SectionLabel('Known limitations'),
            GlassSection(
              children: [
                ElephantTile(
                  icon: Icons.groups_outlined,
                  iconColor: context.glass.warning,
                  title: 'Groups aren\'t end-to-end encrypted yet',
                  subtitle: 'Sender Key encryption for groups is planned.',
                  showChevron: false,
                ),
                ElephantTile(
                  icon: Icons.devices_outlined,
                  iconColor: context.glass.warning,
                  title: 'One device per account',
                  subtitle:
                      'Signing in on a new device creates new keys; contacts will need to re-verify you.',
                  showChevron: false,
                ),
                ElephantTile(
                  icon: Icons.edit_note_rounded,
                  iconColor: context.glass.warning,
                  title: 'Edits aren\'t live',
                  subtitle:
                      'Edited messages update for others when their chat next syncs.',
                  showChevron: false,
                ),
              ],
            ),
            const SectionLabel('Support'),
            GlassSection(
              children: [
                ElephantTile(
                  icon: Icons.bug_report_outlined,
                  title: 'Report an issue',
                  subtitle: 'Open an issue on GitHub',
                  trailing: const Icon(Icons.open_in_new_rounded, size: 18),
                  onTap: () => _open('$githubUrl/issues'),
                ),
                ElephantTile(
                  icon: Icons.code_rounded,
                  title: 'Source code',
                  subtitle: 'github.com/commandlinecoding/elephant',
                  trailing: const Icon(Icons.open_in_new_rounded, size: 18),
                  onTap: () => _open(githubUrl),
                ),
                ElephantTile(
                  icon: Icons.shield_outlined,
                  title: 'Report a security issue',
                  subtitle: 'Privately, through GitHub security advisories',
                  trailing: const Icon(Icons.open_in_new_rounded, size: 18),
                  onTap: () => _open('$githubUrl/security/advisories'),
                ),
              ],
            ),
            const SizedBox(height: Insets.xl),
            Text(
              'Made with 🩵 by CommandLineCoding',
              textAlign: TextAlign.center,
              style: context.text.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Faq extends StatelessWidget {
  final String question;
  final String answer;

  const _Faq({required this.question, required this.answer});

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: context.theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: Insets.lg),
        childrenPadding: const EdgeInsets.fromLTRB(
          Insets.lg,
          0,
          Insets.lg,
          Insets.lg,
        ),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        iconColor: context.colors.primary,
        title: Text(
          question,
          style: context.text.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
        children: [
          Text(
            answer,
            style: context.text.bodyMedium?.copyWith(
              color: context.colors.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}
