import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../models/group.dart';
import '../themes/app_themes.dart';
import 'ui/avatar.dart';

/// Draws a mention inside a message: `@Name`, bold, and marked with a
/// background when it is the person looking at it who is mentioned. Tapping
/// opens the member. The name shown is the member's current one.
class MentionBuilder extends MarkdownElementBuilder {
  final String? myId;
  final Color textColor;
  final String Function(String userId, String stored) nameOf;
  final void Function(String userId)? onTap;

  MentionBuilder({
    required this.myId,
    required this.textColor,
    required this.nameOf,
    this.onTap,
  });

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final id = element.attributes['id'] ?? '';
    final name = nameOf(id, element.textContent);
    final mine = myId != null && id == myId!.toLowerCase();
    return Semantics(
      link: true,
      label: mine ? 'Mentions you' : 'Mention of $name',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap == null ? null : () => onTap!(id),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          decoration: mine
              ? BoxDecoration(
                  color: textColor.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(4),
                )
              : null,
          child: Text(
            '@$name',
            style: (parentStyle ?? preferredStyle)?.copyWith(
              fontWeight: FontWeight.w700,
              color: textColor,
            ),
          ),
        ),
      ),
    );
  }
}

/// Members to pick from while writing an @mention, above the message box.
class MentionSuggestions extends StatelessWidget {
  final List<GroupMember> members;
  final ValueChanged<GroupMember> onPick;

  const MentionSuggestions({
    super.key,
    required this.members,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    // The colour is on a Material, not a box, so the tiles' ink shows.
    return Material(
      color: tokens.panelFill,
      child: Container(
        constraints: const BoxConstraints(maxHeight: 220),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: tokens.hairline)),
        ),
        child: ListView(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          children: [
            for (final member in members)
              ListTile(
                key: ValueKey('mention-${member.userId}'),
                dense: true,
                leading: ElephantAvatar(
                  name: member.displayName,
                  seed: member.userId,
                  size: 32,
                ),
                title: Text(member.displayName),
                subtitle: Text('@${member.username}'),
                onTap: () => onPick(member),
              ),
          ],
        ),
      ),
    );
  }
}
