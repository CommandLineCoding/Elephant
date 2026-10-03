import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:mobile/themes/app_themes.dart';

/// Frosted panel: blurred backdrop, translucent fill, hairline highlight.
/// The base building block of the Elephant look.
class GlassSurface extends StatelessWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry? padding;
  final bool strong;
  final bool showBorder;
  final Color? tint;
  final List<BoxShadow>? shadows;

  const GlassSurface({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(Radii.lg)),
    this.padding,
    this.strong = false,
    this.showBorder = true,
    this.tint,
    this.shadows,
  });

  @override
  Widget build(BuildContext context) {
    final glass = context.glass;
    return DecoratedBox(
      decoration: BoxDecoration(borderRadius: borderRadius, boxShadow: shadows),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: glass.blur, sigmaY: glass.blur),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: tint ?? (strong ? glass.glassStrongFill : glass.glassFill),
              borderRadius: borderRadius,
              border: showBorder
                  ? Border.all(color: glass.glassBorder, width: 1)
                  : null,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Soft, blurred colour fields behind glass. Static by default so long
/// lists stay cheap; [animate] slowly drifts them (used on the welcome screen).
class AmbientBackground extends StatefulWidget {
  final Widget child;
  final bool animate;
  final double intensity;

  const AmbientBackground({
    super.key,
    required this.child,
    this.animate = false,
    this.intensity = 1,
  });

  @override
  State<AmbientBackground> createState() => _AmbientBackgroundState();
}

class _AmbientBackgroundState extends State<AmbientBackground>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  @override
  void initState() {
    super.initState();
    if (widget.animate) {
      _controller = AnimationController(
        vsync: this,
        duration: const Duration(seconds: 14),
      )..repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.glass.ambient;
    final isDark = context.theme.brightness == Brightness.dark;
    final strength = (isDark ? 0.42 : 0.5) * widget.intensity;

    Widget blobs(double t) {
      return LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth;
          final h = box.maxHeight;
          return Stack(
            children: [
              _blob(
                colors[0],
                strength,
                w * 1.1,
                Offset(-w * 0.35 + t * w * 0.25, -h * 0.12 + t * 40),
              ),
              _blob(
                colors[1],
                strength * 0.8,
                w * 0.95,
                Offset(w * 0.45 - t * w * 0.2, h * 0.35 + t * 60),
              ),
              _blob(
                colors[2],
                strength * 0.7,
                w * 0.9,
                Offset(-w * 0.2 + t * w * 0.3, h * 0.75 - t * 50),
              ),
            ],
          );
        },
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: context.theme.scaffoldBackgroundColor),
        RepaintBoundary(
          child: _controller == null
              ? blobs(0)
              : AnimatedBuilder(
                  animation: _controller!,
                  builder: (_, _) =>
                      blobs(Curves.easeInOutSine.transform(_controller!.value)),
                ),
        ),
        widget.child,
      ],
    );
  }

  Widget _blob(Color color, double alpha, double size, Offset offset) {
    return Positioned(
      left: offset.dx,
      top: offset.dy,
      child: IgnorePointer(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                color.withValues(alpha: alpha),
                color.withValues(alpha: 0),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Blurred, translucent app bar used by every pushed screen.
class GlassAppBar extends StatelessWidget implements PreferredSizeWidget {
  final Widget? title;
  final List<Widget>? actions;
  final Widget? leading;
  final bool automaticallyImplyLeading;
  final double height;
  final double? titleSpacing;

  const GlassAppBar({
    super.key,
    this.title,
    this.actions,
    this.leading,
    this.automaticallyImplyLeading = true,
    this.height = kToolbarHeight,
    this.titleSpacing,
  });

  @override
  Size get preferredSize => Size.fromHeight(height);

  @override
  Widget build(BuildContext context) {
    final glass = context.glass;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: glass.blur, sigmaY: glass.blur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: glass.glassStrongFill,
            border: Border(bottom: BorderSide(color: glass.glassBorder)),
          ),
          child: AppBar(
            title: title,
            actions: actions,
            leading: leading,
            titleSpacing: titleSpacing,
            toolbarHeight: height,
            automaticallyImplyLeading: automaticallyImplyLeading,
            backgroundColor: Colors.transparent,
          ),
        ),
      ),
    );
  }
}

/// Backdrop for a [SliverAppBar.flexibleSpace] that frosts what scrolls under it.
class GlassHeaderBackground extends StatelessWidget {
  const GlassHeaderBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final glass = context.glass;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: glass.blur, sigmaY: glass.blur),
        child: Container(color: glass.glassFill),
      ),
    );
  }
}

/// Anything painted with the theme's accent gradient (buttons, badges, icons).
class AccentGradientBox extends StatelessWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry? padding;
  final BoxShape shape;

  const AccentGradientBox({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(Radii.md)),
    this.padding,
    this.shape = BoxShape.rectangle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        gradient: context.glass.accentGradient,
        borderRadius: shape == BoxShape.circle ? null : borderRadius,
        shape: shape,
      ),
      child: child,
    );
  }
}

/// Primary call-to-action: full-width gradient pill with a loading state.
class GradientButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool isLoading;
  final IconData? icon;

  const GradientButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.isLoading = false,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !isLoading;
    final onAccent = context.glass.onAccent;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: enabled || isLoading ? 1 : 0.5,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: context.glass.accentGradient,
          borderRadius: BorderRadius.circular(Radii.md),
          boxShadow: [
            BoxShadow(
              color: context.colors.primary.withValues(
                alpha: enabled ? 0.32 : 0,
              ),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.md),
            onTap: enabled ? onPressed : null,
            child: SizedBox(
              height: 52,
              child: Center(
                child: isLoading
                    ? SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          color: onAccent,
                        ),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (icon != null) ...[
                            Icon(icon, color: onAccent, size: 20),
                            const SizedBox(width: 8),
                          ],
                          Text(
                            label,
                            style: TextStyle(
                              color: onAccent,
                              fontWeight: FontWeight.w700,
                              fontSize: 15.5,
                              letterSpacing: 0.2,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
