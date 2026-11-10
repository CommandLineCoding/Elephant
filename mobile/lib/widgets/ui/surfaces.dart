import 'package:flutter/material.dart';
import 'package:mobile/themes/app_themes.dart';

/// A solid raised surface: opaque fill and a one-pixel border. The base
/// building block for cards, sheets and grouped lists.
class Panel extends StatelessWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry? padding;
  final bool showBorder;
  final Color? tint;

  const Panel({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(Radii.lg)),
    this.padding,
    this.showBorder = true,
    this.tint,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      padding: padding,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: tint ?? tokens.panelFill,
        borderRadius: borderRadius,
        border: showBorder ? Border.all(color: tokens.hairline) : null,
      ),
      child: child,
    );
  }
}

/// The plain page background every screen sits on.
class ScreenBackground extends StatelessWidget {
  final Widget child;

  const ScreenBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    // A Material, not a ColoredBox, so list tiles can paint their ripples.
    return Material(
      color: context.theme.scaffoldBackgroundColor,
      child: child,
    );
  }
}

/// App bar used by every pushed screen: the page colour with a hairline
/// underneath.
class ElephantAppBar extends StatelessWidget implements PreferredSizeWidget {
  final Widget? title;
  final List<Widget>? actions;
  final Widget? leading;
  final bool automaticallyImplyLeading;
  final double height;
  final double? titleSpacing;

  const ElephantAppBar({
    super.key,
    this.title,
    this.actions,
    this.leading,
    this.automaticallyImplyLeading = true,
    this.height = kToolbarHeight,
    this.titleSpacing,
  });

  @override
  Size get preferredSize => Size.fromHeight(height + 1);

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.theme.scaffoldBackgroundColor,
        border: Border(bottom: BorderSide(color: context.tokens.hairline)),
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
    );
  }
}

/// Backdrop for a [SliverAppBar.flexibleSpace]: the page colour with a hairline
/// underneath.
class HeaderBackground extends StatelessWidget {
  const HeaderBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.theme.scaffoldBackgroundColor,
        border: Border(bottom: BorderSide(color: context.tokens.hairline)),
      ),
    );
  }
}

/// Anything painted in the accent colour (badges, icon chips).
class AccentBox extends StatelessWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry? padding;
  final BoxShape shape;

  const AccentBox({
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
        color: context.colors.primary,
        borderRadius: shape == BoxShape.circle ? null : borderRadius,
        shape: shape,
      ),
      child: child,
    );
  }
}

/// Primary call to action: a full-width solid button with a loading state.
class PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool isLoading;
  final IconData? icon;

  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.isLoading = false,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !isLoading;
    final onAccent = context.tokens.onAccent;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 150),
      opacity: enabled || isLoading ? 1 : 0.45,
      child: Material(
        color: context.colors.primary,
        borderRadius: BorderRadius.circular(Radii.md),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onPressed : null,
          child: SizedBox(
            height: 50,
            child: Center(
              child: isLoading
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: onAccent,
                      ),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (icon != null) ...[
                          Icon(icon, color: onAccent, size: 19),
                          const SizedBox(width: 8),
                        ],
                        Text(
                          label,
                          style: context.text.labelLarge?.copyWith(
                            color: onAccent,
                            fontSize: 15,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
