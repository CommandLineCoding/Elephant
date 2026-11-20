import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../controllers/auth_state.dart';
import '../../controllers/chat/group_details_controller.dart';
import '../../controllers/chat/inbox_controller.dart';
import '../../models/inbox_item.dart';
import '../../services/starred_messages.dart';
import '../../themes/app_themes.dart';
import '../../widgets/ui/components.dart';
import 'chat_page.dart';

/// The messages you starred, newest star first: in one chat, or in all of
/// them. Tapping one opens the chat at that message.
class StarredMessagesPage extends StatefulWidget {
  /// Only this chat's messages, or all of them when null.
  final String? chatId;

  const StarredMessagesPage({super.key, this.chatId});

  @override
  State<StarredMessagesPage> createState() => _StarredMessagesPageState();
}

class _StarredMessagesPageState extends State<StarredMessagesPage> {
  late Future<List<StarredEntry>> _entries;

  @override
  void initState() {
    super.initState();
    _entries = StarredMessages.instance.entries(chatId: widget.chatId);
    StarredMessages.instance.addListener(_reload);
  }

  @override
  void dispose() {
    StarredMessages.instance.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    if (!mounted) return;
    setState(() {
      _entries = StarredMessages.instance.entries(chatId: widget.chatId);
    });
  }

  InboxItem? _chatOf(InboxController inbox, String chatId) => inbox.inbox
      .where((c) => c.id.toLowerCase() == chatId.toLowerCase())
      .firstOrNull;

  @override
  Widget build(BuildContext context) {
    final inbox = context.watch<InboxController>();
    return Scaffold(
      appBar: AppBar(title: const Text('Starred messages')),
      body: FutureBuilder<List<StarredEntry>>(
        future: _entries,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          // A starred message whose chat is gone has nowhere to open.
          final entries = [
            for (final e in snapshot.data ?? const <StarredEntry>[])
              if (_chatOf(inbox, e.chatId) != null &&
                  !e.message.isDeleted &&
                  !e.message.isAction)
                e,
          ];
          if (entries.isEmpty) {
            return const EmptyState(
              icon: Icons.star_outline_rounded,
              title: 'No starred messages',
              message:
                  'Long-press a message and choose Star to keep it here. Only you can see them.',
            );
          }
          return ListView.separated(
            itemCount: entries.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final entry = entries[index];
              final chat = _chatOf(inbox, entry.chatId)!;
              final chatName = chat.title.isEmpty
                  ? (chat.username ?? 'Chat')
                  : chat.title;
              final mine = entry.message.isFrom(
                context.read<AuthState>().currentUser?.id,
              );
              final sender = mine
                  ? 'You'
                  : chat.isGroup
                  ? context.read<GroupDetailsController>().nameFor(
                      entry.message.senderId,
                    )
                  : chatName;
              return ListTile(
                title: Text(
                  entry.message.text,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '$sender${widget.chatId == null && chat.isGroup ? ' in $chatName' : ''}'
                  ' · ${DateFormat.yMMMd().add_jm().format(entry.message.createdAt)}',
                ),
                trailing: IconButton(
                  tooltip: 'Remove star',
                  icon: Icon(Icons.star_rounded, color: context.colors.primary),
                  onPressed: () => StarredMessages.instance.setStarred(
                    entry.chatId,
                    entry.message.id,
                    false,
                  ),
                ),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ChatPage(
                      chatUserId: chat.id,
                      displayName: chatName,
                      username: chat.username,
                      isGroup: chat.isGroup,
                      initialMessageId: entry.message.id,
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
