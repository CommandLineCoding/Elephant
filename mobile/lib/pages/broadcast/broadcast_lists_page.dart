import 'package:flutter/material.dart';
import 'package:mobile/pages/broadcast/broadcast_page.dart';
import 'package:mobile/pages/new%20chat/select_contact_page.dart';
import 'package:mobile/services/broadcast_lists.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/ui/components.dart';

/// The row at the top of the chat list that opens [BroadcastListsPage].
class BroadcastListsRow extends StatelessWidget {
  final int count;
  final VoidCallback onTap;

  const BroadcastListsRow({
    super.key,
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Broadcast lists, $count',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.page,
            vertical: 14,
          ),
          child: Row(
            children: [
              SizedBox(
                width: 52,
                child: Icon(
                  Icons.campaign_outlined,
                  color: context.colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: Insets.lg),
              Expanded(
                child: Text(
                  'Broadcast lists',
                  style: context.text.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '$count',
                style: context.text.labelLarge?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The person's broadcast lists, and a way to make another.
class BroadcastListsPage extends StatelessWidget {
  const BroadcastListsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: BroadcastLists.instance,
      builder: (context, _) {
        final lists = BroadcastLists.instance.lists;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Broadcast lists'),
            actions: [
              IconButton(
                tooltip: 'New broadcast',
                icon: const Icon(Icons.add_rounded),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const SelectContactPage(forBroadcast: true),
                  ),
                ),
              ),
            ],
          ),
          body: lists.isEmpty
              ? const EmptyState(
                  icon: Icons.campaign_outlined,
                  title: 'No broadcast lists',
                  message:
                      'Make a list to send one message to several people, '
                      'each on their own.',
                )
              : ListView(
                  children: [
                    for (final list in lists)
                      ListTile(
                        key: ValueKey(list.id),
                        leading: const Icon(Icons.campaign_outlined),
                        title: Text(list.name),
                        subtitle: Text(
                          '${list.members.length} '
                          '${list.members.length == 1 ? 'person' : 'people'}',
                        ),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => BroadcastPage(listId: list.id),
                          ),
                        ),
                      ),
                  ],
                ),
        );
      },
    );
  }
}
