import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../controllers/chat/inbox_controller.dart';
import '../../core/shared_contact.dart';
import '../../widgets/ui/avatar.dart';
import '../../widgets/ui/components.dart';

/// Picks one of the people you chat with to share. Pops with a
/// [SharedContact].
class ContactPickerPage extends StatefulWidget {
  /// Left out of the list: the chat the contact is being shared into.
  final String? exceptId;

  const ContactPickerPage({super.key, this.exceptId});

  @override
  State<ContactPickerPage> createState() => _ContactPickerPageState();
}

class _ContactPickerPageState extends State<ContactPickerPage> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final people = [
      for (final chat in context.watch<InboxController>().inbox)
        if (!chat.isGroup &&
            chat.username != null &&
            chat.id.toLowerCase() != widget.exceptId?.toLowerCase() &&
            (query.isEmpty ||
                chat.title.toLowerCase().contains(query) ||
                chat.username!.toLowerCase().contains(query)))
          chat,
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Share a contact')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: SearchField(
              controller: _search,
              hint: 'Search your chats',
              onChanged: (_) => setState(() {}),
            ),
          ),
          Expanded(
            child: people.isEmpty
                ? const EmptyState(
                    icon: Icons.person_search_rounded,
                    title: 'No one to share',
                    message: 'You can share people you have a chat with.',
                  )
                : ListView.builder(
                    itemCount: people.length,
                    itemBuilder: (context, index) {
                      final chat = people[index];
                      final name = chat.title.isEmpty
                          ? chat.username!
                          : chat.title;
                      return ListTile(
                        leading: ElephantAvatar(
                          name: name,
                          seed: chat.id,
                          size: 44,
                        ),
                        title: Text(name),
                        subtitle: Text('@${chat.username}'),
                        onTap: () => Navigator.pop(
                          context,
                          SharedContact(
                            id: chat.id,
                            name: name,
                            username: chat.username!,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
