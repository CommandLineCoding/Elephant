import 'package:flutter/material.dart';
import 'package:mobile/controllers/chat/active_chat_controller.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/core/message_summary.dart';
import 'package:mobile/models/broadcast_list.dart';
import 'package:mobile/pages/new%20chat/select_contact_page.dart';
import 'package:mobile/services/broadcast_lists.dart';
import 'package:mobile/services/ws_service.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/ui/avatar.dart';
import 'package:mobile/widgets/ui/feedback.dart';
import 'package:provider/provider.dart';

/// A broadcast list: write once, and the message goes to each person on their
/// own, end-to-end encrypted. They don't see each other, and their replies
/// arrive in their own chat with the sender.
class BroadcastPage extends StatefulWidget {
  final String listId;

  const BroadcastPage({super.key, required this.listId});

  @override
  State<BroadcastPage> createState() => _BroadcastPageState();
}

class _BroadcastPageState extends State<BroadcastPage> {
  final _text = TextEditingController();
  bool _sending = false;

  /// What didn't reach some people: the text, and who is left to send it to.
  ({String text, Set<String> to})? _unsent;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  BroadcastList? get _list => BroadcastLists.instance.byId(widget.listId);

  Future<void> _send() async {
    final list = _list;
    final text = _text.text.trim();
    if (list == null || text.isEmpty || _sending) return;
    await _deliver(list, text, {for (final m in list.members) m.id});
  }

  Future<void> _retry() async {
    final list = _list;
    final unsent = _unsent;
    if (list == null || unsent == null || _sending) return;
    await _deliver(list, unsent.text, unsent.to);
  }

  Future<void> _deliver(
    BroadcastList list,
    String text,
    Set<String> recipients,
  ) async {
    setState(() => _sending = true);
    final targets = {
      for (final m in list.members)
        if (recipients.contains(m.id)) m.id: false,
    };
    final failed = await context.read<ActiveChatController>().forward(
      text,
      targets,
    );
    if (!mounted) return;

    final inbox = context.read<InboxController>();
    final now = DateTime.now();
    for (final id in targets.keys.where((id) => !failed.containsKey(id))) {
      inbox.updateLocalInboxState(
        id,
        summarizeContent(text),
        now,
        false,
        senderId: 'me',
        syncStatus: WebSocketService().isConnected ? 'synced' : 'pending',
      );
    }

    final sent = targets.length - failed.length;
    setState(() {
      _sending = false;
      _text.clear();
      _unsent = failed.isEmpty ? null : (text: text, to: failed.keys.toSet());
    });
    if (failed.isEmpty) {
      showSnack(
        context,
        sent == 1 ? 'Sent to 1 person' : 'Sent to $sent people',
      );
      return;
    }
    final names = list.members
        .where((m) => failed.containsKey(m.id))
        .map((m) => m.name.isEmpty ? 'someone' : m.name)
        .join(', ');
    showSnack(
      context,
      "Couldn't send to $names: ${failed.values.first}",
      isError: true,
    );
  }

  Future<void> _delete(BroadcastList list) async {
    final ok = await confirmAction(
      context,
      title: 'Delete "${list.name}"?',
      message:
          'The list goes away. Messages you already sent stay in each '
          'person\'s chat.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await BroadcastLists.instance.delete(list.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: BroadcastLists.instance,
      builder: (context, _) {
        final list = _list;
        if (list == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('This list is gone.')),
          );
        }
        return Scaffold(
          appBar: AppBar(
            title: Text(list.name),
            actions: [
              PopupMenuButton<String>(
                tooltip: 'More',
                onSelected: (value) {
                  if (value == 'edit') {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => SelectContactPage(editing: list),
                      ),
                    );
                  } else if (value == 'delete') {
                    _delete(list);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Edit list')),
                  PopupMenuItem(value: 'delete', child: Text('Delete list')),
                ],
              ),
            ],
          ),
          body: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(Insets.page),
                  children: [
                    Text(
                      'A message here goes to each person on their own, '
                      'end-to-end encrypted. They can\'t see each other, and '
                      'their replies come back in your chat with them.',
                      style: context.text.bodyMedium?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: Insets.lg),
                    Text(
                      '${list.members.length} '
                      '${list.members.length == 1 ? 'person' : 'people'}',
                      style: context.text.titleSmall,
                    ),
                    const SizedBox(height: Insets.sm),
                    for (final m in list.members)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: ElephantAvatar(
                          name: m.name,
                          seed: m.id,
                          size: 40,
                        ),
                        title: Text(m.name.isEmpty ? m.id : m.name),
                      ),
                  ],
                ),
              ),
              if (_unsent != null)
                MaterialBanner(
                  content: Text(
                    'Not sent to ${_unsent!.to.length} '
                    '${_unsent!.to.length == 1 ? 'person' : 'people'}.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: _sending ? null : _retry,
                      child: const Text('Try again'),
                    ),
                    TextButton(
                      onPressed: () => setState(() => _unsent = null),
                      child: const Text('Dismiss'),
                    ),
                  ],
                ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Insets.page,
                    Insets.sm,
                    Insets.sm,
                    Insets.sm,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _text,
                          minLines: 1,
                          maxLines: 5,
                          textCapitalization: TextCapitalization.sentences,
                          decoration: InputDecoration(
                            hintText: 'Message to ${list.name}',
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Send to ${list.members.length} people',
                        icon: _sending
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.send_rounded),
                        onPressed: _sending || _text.text.trim().isEmpty
                            ? null
                            : _send,
                      ),
                    ],
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
