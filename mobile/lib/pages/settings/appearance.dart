import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile/pages/settings/chat_wallpaper.dart';
import 'package:mobile/services/chat_appearance.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/themes/theme_provider.dart';
import 'package:mobile/widgets/ui/components.dart';
import 'package:mobile/widgets/ui/surfaces.dart';
import 'package:provider/provider.dart';

class AppearanceSettings extends StatelessWidget {
  const AppearanceSettings({super.key});

  Future<void> _chooseTextSize(BuildContext context) async {
    final chosen = await showDialog<MessageTextSize>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Message text size'),
        children: [
          for (final size in MessageTextSize.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, size),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      size.label,
                      style: TextStyle(fontSize: 16 * size.scale),
                    ),
                  ),
                  if (size == ChatAppearance.instance.textSize)
                    const Icon(Icons.check_rounded),
                ],
              ),
            ),
        ],
      ),
    );
    if (chosen != null) await ChatAppearance.instance.setTextSize(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final themes = context.watch<ThemeProvider>();
    final current = themes.currentTheme;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: const ElephantAppBar(title: Text('Appearance')),
      body: ScreenBackground(
        child: ListView(
          padding: EdgeInsets.only(
            top: MediaQuery.paddingOf(context).top + kToolbarHeight,
            bottom: Insets.xxl + MediaQuery.paddingOf(context).bottom,
          ),
          children: [
            const SizedBox(height: Insets.md),
            Section(
              children: [
                ElephantTile(
                  icon: Icons.brightness_auto_outlined,
                  title: 'Match system',
                  subtitle:
                      'Frost when your phone is in light mode, Nebula in dark mode',
                  showChevron: false,
                  trailing: Switch(
                    value: themes.followsSystem,
                    onChanged: (on) {
                      HapticFeedback.selectionClick();
                      on ? themes.followSystem() : themes.setTheme(current);
                    },
                  ),
                ),
              ],
            ),
            const SectionLabel('Chats'),
            ListenableBuilder(
              listenable: ChatAppearance.instance,
              builder: (context, _) => Section(
                children: [
                  ElephantTile(
                    icon: Icons.wallpaper_rounded,
                    title: 'Chat wallpaper',
                    subtitle: ChatAppearance.instance.wallpaper.name,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const ChatWallpaperPage(),
                      ),
                    ),
                  ),
                  ElephantTile(
                    icon: Icons.format_size_rounded,
                    title: 'Message text size',
                    subtitle: ChatAppearance.instance.textSize.label,
                    onTap: () => _chooseTextSize(context),
                  ),
                ],
              ),
            ),
            const SectionLabel('Theme'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.page),
              child: GridView.count(
                // Without this the grid pads itself by MediaQuery.padding,
                // repeating the status bar and app bar height.
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: 2,
                mainAxisSpacing: Insets.lg,
                crossAxisSpacing: Insets.lg,
                childAspectRatio: 0.72,
                children: [
                  for (final type in ThemeType.values)
                    _ThemeCard(type: type, selected: type == current),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Insets.page + 4,
                Insets.xl,
                Insets.page + 4,
                0,
              ),
              child: Text(
                'Every theme uses the same layout; only the colours change.',
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A miniature of the chat screen painted in [type]'s palette.
class _ThemeCard extends StatelessWidget {
  final ThemeType type;
  final bool selected;

  const _ThemeCard({required this.type, required this.selected});

  @override
  Widget build(BuildContext context) {
    final p = AppThemes.paletteOf(type);

    Widget bubble(String text, {required bool mine, double width = 92}) {
      return Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          width: width,
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: mine ? p.accent : p.incomingBubble,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(14),
              topRight: const Radius.circular(14),
              bottomLeft: Radius.circular(mine ? 14 : 4),
              bottomRight: Radius.circular(mine ? 4 : 14),
            ),
          ),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: AppThemes.fontFamily,
              fontSize: 10.5,
              color: mine ? p.onAccent : p.text,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        context.read<ThemeProvider>().setTheme(type);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.xl),
          border: Border.all(
            color: selected ? p.accent : context.colors.outline,
            width: selected ? 2.5 : 1,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(Radii.xl - 2),
          child: Stack(
            children: [
              Positioned.fill(child: ColoredBox(color: p.background)),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: p.accent,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          width: 48,
                          height: 7,
                          decoration: BoxDecoration(
                            color: p.text.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ],
                    ),
                    // Decorative preview: clip from the top instead of
                    // overflowing when fonts are large.
                    Expanded(
                      child: ClipRect(
                        child: OverflowBox(
                          alignment: Alignment.bottomCenter,
                          maxHeight: double.infinity,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              bubble('Hey! 👋', mine: false, width: 64),
                              bubble('Is this encrypted?', mine: true),
                              bubble('End to end 🔒', mine: false, width: 84),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                p.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: p.text,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 15,
                                ),
                              ),
                              Text(
                                p.tagline,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: p.muted,
                                  fontSize: 10.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                        AnimatedScale(
                          scale: selected ? 1 : 0,
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOutBack,
                          child: Container(
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: p.accent,
                            ),
                            child: Icon(
                              Icons.check_rounded,
                              size: 14,
                              color: p.onAccent,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
