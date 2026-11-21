import 'package:flutter/material.dart';
import 'package:mobile/core/chat_wallpaper.dart';
import 'package:mobile/services/chat_appearance.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/ui/components.dart';
import 'package:mobile/widgets/ui/surfaces.dart';

/// Pick a chat wallpaper: for all chats, or, with [chatId], for one chat.
class ChatWallpaperPage extends StatelessWidget {
  /// The chat this is for, or null for all chats.
  final String? chatId;
  final String? chatName;

  const ChatWallpaperPage({super.key, this.chatId, this.chatName});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: ElephantAppBar(
        title: Text(chatId == null ? 'Chat wallpaper' : 'Wallpaper'),
      ),
      body: ScreenBackground(
        child: ListenableBuilder(
          listenable: ChatAppearance.instance,
          builder: (context, _) {
            final appearance = ChatAppearance.instance;
            final own = chatId != null && appearance.hasOwnWallpaper(chatId!);
            final selected = chatId == null
                ? appearance.wallpaper
                : (own ? appearance.wallpaperFor(chatId!) : null);
            return ListView(
              padding: EdgeInsets.only(
                top: MediaQuery.paddingOf(context).top + kToolbarHeight,
                bottom: Insets.xxl + MediaQuery.paddingOf(context).bottom,
              ),
              children: [
                const SizedBox(height: Insets.md),
                if (chatId != null)
                  Section(
                    children: [
                      ElephantTile(
                        icon: Icons.undo_rounded,
                        title: 'Same as all chats',
                        subtitle: appearance.wallpaper.name,
                        showChevron: false,
                        trailing: own ? null : const Icon(Icons.check_rounded),
                        onTap: () => appearance.setWallpaperFor(chatId!, null),
                      ),
                    ],
                  ),
                SectionLabel(
                  chatId == null
                      ? 'For all chats'
                      : 'Only for ${chatName ?? 'this chat'}',
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Insets.page),
                  child: GridView.count(
                    padding: EdgeInsets.zero,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    crossAxisCount: 3,
                    mainAxisSpacing: Insets.md,
                    crossAxisSpacing: Insets.md,
                    childAspectRatio: 0.62,
                    children: [
                      for (final w in Wallpaper.all)
                        _WallpaperCard(
                          wallpaper: w,
                          selected: selected?.id == w.id,
                          onTap: () => chatId == null
                              ? appearance.setWallpaper(w)
                              : appearance.setWallpaperFor(chatId!, w),
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// A miniature chat on [wallpaper], with a bubble each way.
class _WallpaperCard extends StatelessWidget {
  final Wallpaper wallpaper;
  final bool selected;
  final VoidCallback onTap;

  const _WallpaperCard({
    required this.wallpaper,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = context.colors.primary;
    return Semantics(
      button: true,
      selected: selected,
      label: '${wallpaper.name} wallpaper',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          children: [
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(Radii.md),
                  border: Border.all(
                    color: selected ? accent : context.colors.outline,
                    width: selected ? 2.5 : 1,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(Radii.md - 1),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: WallpaperView(wallpaper: wallpaper),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _bubble(context, mine: false),
                            const SizedBox(height: 6),
                            _bubble(context, mine: true),
                          ],
                        ),
                      ),
                      if (selected)
                        Positioned(
                          top: 4,
                          right: 4,
                          child: Icon(
                            Icons.check_circle_rounded,
                            size: 18,
                            color: accent,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(wallpaper.name, style: context.text.labelMedium),
          ],
        ),
      ),
    );
  }

  Widget _bubble(BuildContext context, {required bool mine}) => Align(
    alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
    child: Container(
      width: 40,
      height: 12,
      decoration: BoxDecoration(
        color: mine
            ? context.colors.primary
            : context.colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
    ),
  );
}
