import 'package:flutter/material.dart';

import '../core/link_preview.dart';
import '../themes/app_themes.dart';

/// A link's preview inside a message bubble. Tapping it asks before opening
/// the link.
class LinkPreviewCard extends StatelessWidget {
  final LinkPreview preview;
  final Color textColor;
  final VoidCallback onOpen;

  const LinkPreviewCard({
    super.key,
    required this.preview,
    required this.textColor,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final muted = textColor.withValues(alpha: 0.7);
    return Semantics(
      button: true,
      label: 'Link preview: ${preview.title}. ${preview.siteLabel}. Open link',
      excludeSemantics: true,
      child: Material(
        color: textColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(Radii.sm),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.sm),
          onTap: onOpen,
          child: Container(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: textColor.withValues(alpha: 0.6),
                  width: 3,
                ),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  preview.siteLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: muted, fontSize: 12),
                ),
                const SizedBox(height: 2),
                Text(
                  preview.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: textColor,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (preview.description != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    preview.description!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: textColor, fontSize: 13),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The preview above the message box while writing, with a way to leave it
/// out.
class LinkPreviewBar extends StatelessWidget {
  final LinkPreview preview;
  final VoidCallback onClose;

  const LinkPreviewBar({
    super.key,
    required this.preview,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      margin: const EdgeInsets.fromLTRB(Insets.md, 0, Insets.md, Insets.sm),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: tokens.panelFill,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: tokens.hairline),
      ),
      child: Row(
        children: [
          Icon(Icons.link_rounded, color: context.colors.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  preview.siteLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.labelSmall?.copyWith(
                    color: context.colors.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  preview.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.bodyMedium,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Send without a preview',
            icon: const Icon(Icons.close_rounded),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}
