import 'package:flutter/material.dart';
import 'package:mobile/controllers/auth_state.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/pages/status/status_composer_page.dart';
import 'package:mobile/pages/status/status_viewer_page.dart';
import 'package:mobile/services/nicknames.dart';
import 'package:mobile/services/statuses.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/ui/avatar.dart';
import 'package:provider/provider.dart';

/// The row at the top of Chats: the person's own status first, then the people
/// they chat with who have one, those with something new ringed.
class StatusStrip extends StatelessWidget {
  /// Replaced in tests.
  final Statuses? statuses;

  const StatusStrip({super.key, this.statuses});

  @override
  Widget build(BuildContext context) {
    final source = statuses ?? Statuses.instance;
    final myId = context.read<AuthState>().currentUser?.id.toLowerCase() ?? '';
    return ListenableBuilder(
      listenable: Listenable.merge([source, Nicknames.instance]),
      builder: (context, _) {
        final others = source.others(myId);
        final mine = source.postsBy(myId);
        final inbox = context.watch<InboxController>().inbox;
        String nameOf(String id) {
          final item = inbox.where((i) => i.id.toLowerCase() == id).firstOrNull;
          final title = item == null || item.title.isEmpty
              ? (item?.username ?? 'Contact')
              : item.title;
          return Nicknames.instance.nameFor(id, title);
        }

        void openViewer(List<String> authors) => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                StatusViewerPage(authors: authors, statuses: statuses),
          ),
        );
        void compose() => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => StatusComposerPage(statuses: statuses),
          ),
        );

        return SizedBox(
          // The picture and its padding, and a line of text that grows with the
          // person's text size.
          height: 80 + MediaQuery.textScalerOf(context).scale(18),
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: Insets.page),
            children: [
              _Tile(
                key: const ValueKey('status-mine'),
                name: 'Your status',
                label: 'Your status',
                seed: myId,
                ring: mine.isEmpty ? _Ring.none : _Ring.seen,
                showAdd: true,
                onTap: mine.isEmpty ? compose : () => openViewer([myId]),
                onAdd: compose,
              ),
              for (var i = 0; i < others.length; i++)
                _Tile(
                  key: ValueKey('status-${others[i].authorId}'),
                  name: nameOf(others[i].authorId),
                  seed: others[i].authorId,
                  ring: others[i].unseen ? _Ring.unseen : _Ring.seen,
                  onTap: () => openViewer([
                    for (final o in others.skip(i)) o.authorId,
                    for (final o in others.take(i)) o.authorId,
                  ]),
                ),
            ],
          ),
        );
      },
    );
  }
}

enum _Ring { none, unseen, seen }

class _Tile extends StatelessWidget {
  final String name;

  /// What is written under the picture; the first name by default.
  final String? label;
  final String seed;
  final _Ring ring;
  final bool showAdd;
  final VoidCallback onTap;
  final VoidCallback? onAdd;

  const _Tile({
    super.key,
    required this.name,
    this.label,
    required this.seed,
    required this.ring,
    required this.onTap,
    this.showAdd = false,
    this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    final color = switch (ring) {
      _Ring.unseen => context.colors.primary,
      _Ring.seen => context.colors.outline,
      _Ring.none => Colors.transparent,
    };
    return Semantics(
      button: true,
      label: switch (ring) {
        _Ring.unseen => '$name, new status',
        _Ring.seen => '$name, status',
        _Ring.none => name,
      },
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: 72,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Insets.sm),
            child: Column(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: color,
                          width: ring == _Ring.unseen ? 3 : 2,
                        ),
                      ),
                      child: ElephantAvatar(name: name, seed: seed, size: 46),
                    ),
                    if (showAdd)
                      Positioned(
                        right: -2,
                        bottom: -2,
                        child: GestureDetector(
                          onTap: onAdd,
                          child: Semantics(
                            button: true,
                            label: 'New status',
                            excludeSemantics: true,
                            child: CircleAvatar(
                              radius: 11,
                              backgroundColor: context.colors.primary,
                              child: Icon(
                                Icons.add_rounded,
                                size: 16,
                                color: context.colors.onPrimary,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  label ?? name.split(' ').first,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
