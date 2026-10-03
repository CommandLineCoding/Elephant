import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile/controllers/auth_state.dart';
import 'package:mobile/core/constants.dart';
import 'package:mobile/pages/settings/accounts.dart';
import 'package:mobile/pages/settings/appearance.dart';
import 'package:mobile/pages/settings/help_about.dart';
import 'package:mobile/pages/settings/privacy_security.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/themes/theme_provider.dart';
import 'package:mobile/widgets/ui/avatar.dart';
import 'package:mobile/widgets/ui/components.dart';
import 'package:mobile/widgets/ui/feedback.dart';
import 'package:mobile/widgets/ui/glass.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Shows the signed-in user's username as a QR code so others can find them.
void showUserCard(BuildContext context) {
  final user = context.read<AuthState>().currentUser;
  final username = user?.username ?? '';
  showGlassSheet(
    context,
    builder: (sheetContext) {
      final fg = sheetContext.colors.onSurface;
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          Insets.xl,
          Insets.sm,
          Insets.xl,
          Insets.xl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ElephantAvatar(
              name: user?.displayName ?? '?',
              seed: user?.id ?? '',
              size: 64,
            ),
            const SizedBox(height: Insets.md),
            Text(user?.displayName ?? '', style: sheetContext.text.titleLarge),
            Text(
              '@$username',
              style: sheetContext.text.bodyMedium?.copyWith(
                color: sheetContext.colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Insets.xl),
            GlassSurface(
              borderRadius: BorderRadius.circular(Radii.xl),
              padding: const EdgeInsets.all(Insets.xl),
              child: QrImageView(
                data: username,
                size: 200,
                eyeStyle: QrEyeStyle(eyeShape: QrEyeShape.circle, color: fg),
                dataModuleStyle: QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.circle,
                  color: fg,
                ),
              ),
            ),
            const SizedBox(height: Insets.lg),
            Text(
              'Friends can search for this username to message you.',
              textAlign: TextAlign.center,
              style: sheetContext.text.bodySmall?.copyWith(
                color: sheetContext.colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Insets.xl),
            GradientButton(
              label: 'Copy username',
              icon: Icons.copy_rounded,
              onPressed: () {
                Clipboard.setData(ClipboardData(text: username));
                Navigator.pop(sheetContext);
                showSnack(context, 'Username copied');
              },
            ),
          ],
        ),
      );
    },
  );
}

/// The "You" tab: profile card and settings.
class SettingsPage extends StatelessWidget {
  final bool embedded;

  const SettingsPage({super.key, this.embedded = false});

  void _push(BuildContext context, Widget page) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthState>().currentUser;
    final palette = context.watch<ThemeProvider>().palette;

    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        SliverAppBar(
          pinned: true,
          automaticallyImplyLeading: !embedded,
          backgroundColor: Colors.transparent,
          flexibleSpace: const GlassHeaderBackground(),
          title: const Text('You'),
          actions: [
            IconButton(
              tooltip: 'My QR code',
              icon: const Icon(Icons.qr_code_rounded),
              onPressed: () => showUserCard(context),
            ),
            const SizedBox(width: Insets.sm),
          ],
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              Insets.page,
              Insets.md,
              Insets.page,
              0,
            ),
            child: GlassSurface(
              borderRadius: BorderRadius.circular(Radii.xl),
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  onTap: () => _push(context, const AccountsSettings()),
                  child: Padding(
                    padding: const EdgeInsets.all(Insets.lg),
                    child: Row(
                      children: [
                        Hero(
                          tag: 'me-avatar',
                          child: ElephantAvatar(
                            name: user?.displayName ?? '?',
                            seed: user?.id ?? '',
                            size: 68,
                          ),
                        ),
                        const SizedBox(width: Insets.lg),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                user?.displayName ?? 'Loading profile…',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: context.text.titleLarge,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                user != null ? '@${user.username}' : '',
                                style: context.text.bodyMedium?.copyWith(
                                  color: context.colors.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          Icons.chevron_right_rounded,
                          color: context.colors.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        SliverList.list(
          children: [
            const SectionLabel('Settings'),
            GlassSection(
              children: [
                ElephantTile(
                  icon: Icons.person_outline_rounded,
                  title: 'Account',
                  subtitle: 'Username, server and sign out',
                  onTap: () => _push(context, const AccountsSettings()),
                ),
                ElephantTile(
                  icon: Icons.shield_outlined,
                  title: 'Privacy & security',
                  subtitle: 'Encryption keys and sessions',
                  onTap: () =>
                      _push(context, const PrivacySecuritySettingsPage()),
                ),
                ElephantTile(
                  icon: Icons.palette_outlined,
                  title: 'Appearance',
                  subtitle: palette.name,
                  onTap: () => _push(context, const AppearanceSettings()),
                ),
              ],
            ),
            const SectionLabel('About'),
            GlassSection(
              children: [
                ElephantTile(
                  icon: Icons.help_outline_rounded,
                  title: 'Help & about',
                  onTap: () => _push(context, const HelpAboutPage()),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.all(Insets.xl),
              child: Text(
                Env.isDefaultServer
                    ? 'Connected to Elephant Cloud'
                    : 'Connected to ${Env.host}:${Env.port}',
                textAlign: TextAlign.center,
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 120),
          ],
        ),
      ],
    );
  }
}
