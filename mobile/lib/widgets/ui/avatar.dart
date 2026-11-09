import 'package:flutter/material.dart';
import 'package:mobile/themes/app_themes.dart';

/// Monogram avatar in a flat colour derived from the user or group ID, so the
/// same person always gets the same colour. People are circles; groups are
/// rounded squares, so the two are distinguishable at a glance.
class ElephantAvatar extends StatelessWidget {
  final String name;
  final String seed;
  final double size;
  final bool isGroup;
  final bool? isOnline;
  final bool showSelected;

  const ElephantAvatar({
    super.key,
    required this.name,
    required this.seed,
    this.size = 48,
    this.isGroup = false,
    this.isOnline,
    this.showSelected = false,
  });

  /// Muted, flat hues that all hold white initials at 4.4:1 or better.
  static const List<Color> _colors = [
    Color(0xFF4F5FE0),
    Color(0xFF2A8577),
    Color(0xFFB85A33),
    Color(0xFF9A4A78),
    Color(0xFF3F8244),
    Color(0xFFB14852),
    Color(0xFF2F7BA3),
    Color(0xFF7C5CBA),
  ];

  /// The colour for a person or group, derived from its ID so the same one
  /// always gets the same colour.
  static Color colorFor(String seed) {
    int hash = 0;
    for (final unit in seed.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return _colors[hash % _colors.length];
  }

  static String initialsOf(String name) {
    final words = name
        .trim()
        .split(RegExp(r'[\s._-]+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return '?';
    if (words.length == 1) {
      return words.first.characters.take(2).toString().toUpperCase();
    }
    return (words[0].characters.first + words[1].characters.first)
        .toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final color = colorFor(seed.isEmpty ? name : seed);
    final radius = isGroup
        ? BorderRadius.circular(size * 0.32)
        : BorderRadius.circular(size / 2);

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(borderRadius: radius, color: color),
            alignment: Alignment.center,
            child: isGroup && name.trim().isEmpty
                ? Icon(
                    Icons.groups_rounded,
                    color: Colors.white,
                    size: size * 0.5,
                  )
                : Text(
                    initialsOf(name),
                    style: context.text.labelLarge?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: size * 0.34,
                      letterSpacing: 0.3,
                    ),
                  ),
          ),
          if (isOnline != null)
            Positioned(
              right: isGroup ? -2 : 0,
              bottom: isGroup ? -2 : 0,
              child: AnimatedScale(
                scale: isOnline! ? 1 : 0,
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutBack,
                child: Container(
                  width: size * 0.28,
                  height: size * 0.28,
                  decoration: BoxDecoration(
                    color: context.tokens.success,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: context.theme.scaffoldBackgroundColor,
                      width: size * 0.05,
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            right: -3,
            bottom: -3,
            child: AnimatedScale(
              scale: showSelected ? 1 : 0,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutBack,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: context.theme.scaffoldBackgroundColor,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.check_circle_rounded,
                  size: size * 0.36,
                  color: context.colors.primary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
