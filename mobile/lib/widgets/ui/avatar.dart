import 'package:flutter/material.dart';
import 'package:mobile/themes/app_themes.dart';

/// Monogram avatar with a gradient derived from the user or group ID, so the
/// same person always gets the same colours. People are circles; groups are
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

  static const List<List<Color>> _gradients = [
    [Color(0xFF6A8DFF), Color(0xFF8E6BFF)],
    [Color(0xFF2EC4B6), Color(0xFF3A86FF)],
    [Color(0xFFFF7A59), Color(0xFFFFB443)],
    [Color(0xFFEC4899), Color(0xFF8B5CF6)],
    [Color(0xFF10B981), Color(0xFF84CC16)],
    [Color(0xFFF43F5E), Color(0xFFFB923C)],
    [Color(0xFF0EA5E9), Color(0xFF22D3EE)],
    [Color(0xFFA855F7), Color(0xFFF472B6)],
  ];

  static List<Color> gradientFor(String seed) {
    int hash = 0;
    for (final unit in seed.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return _gradients[hash % _gradients.length];
  }

  /// Accent colour for a person, e.g. their name in group chats.
  static Color colorFor(String seed) => gradientFor(seed).first;

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
    final colors = gradientFor(seed.isEmpty ? name : seed);
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
            decoration: BoxDecoration(
              borderRadius: radius,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: colors,
              ),
              boxShadow: [
                BoxShadow(
                  color: colors.last.withValues(alpha: 0.25),
                  blurRadius: size * 0.25,
                  offset: Offset(0, size * 0.08),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: isGroup && name.trim().isEmpty
                ? Icon(
                    Icons.groups_rounded,
                    color: Colors.white,
                    size: size * 0.5,
                  )
                : Text(
                    initialsOf(name),
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: size * 0.36,
                      letterSpacing: 0.5,
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
                    color: context.glass.success,
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
