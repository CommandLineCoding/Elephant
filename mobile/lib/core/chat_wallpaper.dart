import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The pattern drawn over a wallpaper's colour.
enum WallpaperPattern { none, dots, grid, waves, diamonds }

/// A chat background: a light wash of colour, with a pattern over it. The wash
/// and the pattern are blended into the theme's own colours, so the text on
/// top stays readable in the light and the dark themes alike. Nothing is
/// downloaded or stored as an image: the patterns are drawn.
class Wallpaper {
  final String id;
  final String name;

  /// The colour washed over the theme's background, or null for none.
  final Color? tint;
  final WallpaperPattern pattern;

  const Wallpaper(this.id, this.name, {this.tint, required this.pattern});

  /// How strong the wash is. Light enough that body text keeps its contrast.
  static const tintStrength = 0.16;

  /// How strong the pattern's lines are.
  static const patternStrength = 0.08;

  /// The chat's background colour: [base] with the wash over it.
  Color background(Color base) => tint == null
      ? base
      : Color.alphaBlend(tint!.withValues(alpha: tintStrength), base);

  static const none = Wallpaper(
    'none',
    'Plain',
    pattern: WallpaperPattern.none,
  );

  static const all = <Wallpaper>[
    none,
    Wallpaper(
      'sage',
      'Sage',
      tint: Color(0xFF3F8F5F),
      pattern: WallpaperPattern.none,
    ),
    Wallpaper(
      'sky',
      'Sky',
      tint: Color(0xFF2F7FD1),
      pattern: WallpaperPattern.none,
    ),
    Wallpaper(
      'sand',
      'Sand',
      tint: Color(0xFFC9923B),
      pattern: WallpaperPattern.none,
    ),
    Wallpaper(
      'rose',
      'Rose',
      tint: Color(0xFFD1507A),
      pattern: WallpaperPattern.none,
    ),
    Wallpaper(
      'lilac',
      'Lilac',
      tint: Color(0xFF8A62D6),
      pattern: WallpaperPattern.none,
    ),
    Wallpaper(
      'dots',
      'Dots',
      tint: Color(0xFF2F7FD1),
      pattern: WallpaperPattern.dots,
    ),
    Wallpaper(
      'grid',
      'Grid',
      tint: Color(0xFF3F8F5F),
      pattern: WallpaperPattern.grid,
    ),
    Wallpaper(
      'waves',
      'Waves',
      tint: Color(0xFF8A62D6),
      pattern: WallpaperPattern.waves,
    ),
    Wallpaper(
      'diamonds',
      'Diamonds',
      tint: Color(0xFFC9923B),
      pattern: WallpaperPattern.diamonds,
    ),
  ];

  /// The wallpaper with this ID, or [none] if it isn't one (a saved ID from a
  /// version that had a different set).
  static Wallpaper byId(String? id) =>
      all.firstWhere((w) => w.id == id, orElse: () => none);
}

/// Paints [wallpaper] to fill its space, behind the messages.
class WallpaperView extends StatelessWidget {
  final Wallpaper wallpaper;

  const WallpaperView({super.key, required this.wallpaper});

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).scaffoldBackgroundColor;
    final ink = Theme.of(context).colorScheme.onSurface;
    return ExcludeSemantics(
      child: IgnorePointer(
        child: CustomPaint(
          painter: _WallpaperPainter(
            background: wallpaper.background(base),
            lines: ink.withValues(alpha: Wallpaper.patternStrength),
            pattern: wallpaper.pattern,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _WallpaperPainter extends CustomPainter {
  final Color background;
  final Color lines;
  final WallpaperPattern pattern;

  const _WallpaperPainter({
    required this.background,
    required this.lines,
    required this.pattern,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = background);
    final stroke = Paint()
      ..color = lines
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final fill = Paint()..color = lines;

    switch (pattern) {
      case WallpaperPattern.none:
        break;
      case WallpaperPattern.dots:
        const gap = 28.0;
        for (var y = gap / 2; y < size.height; y += gap) {
          for (var x = gap / 2; x < size.width; x += gap) {
            canvas.drawCircle(Offset(x, y), 1.6, fill);
          }
        }
      case WallpaperPattern.grid:
        const gap = 36.0;
        for (var x = 0.0; x < size.width; x += gap) {
          canvas.drawLine(Offset(x, 0), Offset(x, size.height), stroke);
        }
        for (var y = 0.0; y < size.height; y += gap) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), stroke);
        }
      case WallpaperPattern.waves:
        const gap = 34.0;
        for (var y = gap / 2; y < size.height + gap; y += gap) {
          final path = Path()..moveTo(0, y);
          for (var x = 0.0; x < size.width; x += 4) {
            path.lineTo(x, y + math.sin(x / 22) * 5);
          }
          canvas.drawPath(path, stroke);
        }
      case WallpaperPattern.diamonds:
        const gap = 44.0;
        for (var y = 0.0; y < size.height + gap; y += gap) {
          for (var x = 0.0; x < size.width + gap; x += gap) {
            final c = Offset(x + (y / gap).floor() % 2 * gap / 2, y);
            canvas.drawPath(
              Path()
                ..moveTo(c.dx, c.dy - 7)
                ..lineTo(c.dx + 7, c.dy)
                ..lineTo(c.dx, c.dy + 7)
                ..lineTo(c.dx - 7, c.dy)
                ..close(),
              stroke,
            );
          }
        }
    }
  }

  @override
  bool shouldRepaint(_WallpaperPainter old) =>
      old.background != background ||
      old.lines != lines ||
      old.pattern != pattern;
}
