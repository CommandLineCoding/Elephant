import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/themes/theme_provider.dart';
import 'package:mobile/widgets/ui/components.dart';
import 'package:mobile/widgets/ui/glass.dart';
import 'package:provider/provider.dart';

class AppearanceSettings extends StatelessWidget {
  const AppearanceSettings({super.key});

  @override
  Widget build(BuildContext context) {
    final current = context.watch<ThemeProvider>().currentTheme;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: const GlassAppBar(title: Text('Appearance')),
      body: AmbientBackground(
        child: ListView(
          padding: EdgeInsets.only(
            top: MediaQuery.paddingOf(context).top + kToolbarHeight,
            bottom: Insets.xxl + MediaQuery.paddingOf(context).bottom,
          ),
          children: [
            const SectionLabel('Theme'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.page),
              child: GridView.count(
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
                'Every theme uses the same frosted-glass surfaces; only the light and colour change.',
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
    final gradient = LinearGradient(colors: [p.accent, p.accentAlt]);

    Widget bubble(String text, {required bool mine, double width = 92}) {
      return Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          width: width,
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            gradient: mine ? gradient : null,
            color: mine ? null : p.incomingBubble,
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
          boxShadow: [
            BoxShadow(
              color: (selected ? p.accent : Colors.black).withValues(
                alpha: selected ? 0.35 : 0.08,
              ),
              blurRadius: selected ? 22 : 12,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(Radii.xl - 2),
          child: Stack(
            children: [
              Positioned.fill(child: ColoredBox(color: p.background)),
              Positioned(
                top: -40,
                left: -30,
                child: Container(
                  width: 160,
                  height: 160,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        p.ambient[0].withValues(alpha: 0.5),
                        p.ambient[0].withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                bottom: -30,
                right: -40,
                child: Container(
                  width: 150,
                  height: 150,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        p.ambient[1].withValues(alpha: 0.45),
                        p.ambient[1].withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
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
                            gradient: gradient,
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
                              gradient: gradient,
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
