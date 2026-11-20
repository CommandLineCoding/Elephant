import 'package:flutter/material.dart';
import 'package:mobile/controllers/chat/active_chat_controller.dart';
import 'package:mobile/core/message_payload.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/models/inbox_item.dart';
import 'package:mobile/services/ws_service.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/ui/avatar.dart';
import 'package:mobile/widgets/ui/components.dart';
import 'package:mobile/widgets/ui/feedback.dart';
import 'package:mobile/widgets/ui/surfaces.dart';
import 'package:provider/provider.dart';

/// Picks one or more chats and sends [text] to each as a new message.
class ForwardPage extends StatefulWidget {
  final String text;

  const ForwardPage({super.key, required this.text});

  @override
  State<ForwardPage> createState() => _ForwardPageState();
}

class _ForwardPageState extends State<ForwardPage> {
  final _search = TextEditingController();
  final Set<String> _selected = {};
  String _query = '';
  bool _sending = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String _titleOf(InboxItem item) =>
      item.title.isEmpty ? (item.username ?? '') : item.title;

  Future<void> _send(List<InboxItem> chats) async {
    final targets = {
      for (final item in chats.where((c) => _selected.contains(c.id)))
        item.id: item.isGroup,
    };
    setState(() => _sending = true);
    final failed = await context.read<ActiveChatController>().forward(
      widget.text,
      targets,
    );
    if (!mounted) return;

    final inbox = context.read<InboxController>();
    final now = DateTime.now();
    for (final chatId in targets.keys.where((id) => !failed.containsKey(id))) {
      inbox.updateLocalInboxState(
        chatId,
        MessagePayload.readable(widget.text),
        now,
        false,
        senderId: 'me',
        syncStatus: WebSocketService().isConnected ? 'synced' : 'pending',
      );
    }

    final sent = targets.length - failed.length;
    if (failed.isEmpty) {
      showSnack(context, sent == 1 ? 'Forwarded' : 'Forwarded to $sent chats');
      Navigator.pop(context);
      return;
    }
    final names = chats
        .where((c) => failed.containsKey(c.id))
        .map(_titleOf)
        .join(', ');
    setState(() {
      _sending = false;
      _selected.removeWhere((id) => !failed.containsKey(id));
    });
    showSnack(
      context,
      "Couldn't forward to $names: ${failed.values.first}",
      isError: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final all = context.watch<InboxController>().inbox;
    final q = _query.toLowerCase();
    final chats = q.isEmpty
        ? all
        : all
              .where(
                (c) =>
                    c.title.toLowerCase().contains(q) ||
                    (c.username?.toLowerCase().contains(q) ?? false),
              )
              .toList();

    return Scaffold(
      appBar: const ElephantAppBar(title: Text('Forward to')),
      body: ScreenBackground(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Insets.page,
                Insets.md,
                Insets.page,
                Insets.sm,
              ),
              child: SearchField(
                controller: _search,
                hint: 'Search chats',
                onChanged: (v) => setState(() => _query = v.trim()),
              ),
            ),
            Expanded(
              child: chats.isEmpty
                  ? const EmptyState(
                      icon: Icons.forum_outlined,
                      title: 'No chats to forward to',
                      message: 'Start a chat first, then forward to it.',
                    )
                  : ListView.builder(
                      itemCount: chats.length,
                      itemBuilder: (context, i) {
                        final item = chats[i];
                        final selected = _selected.contains(item.id);
                        return CheckboxListTile(
                          value: selected,
                          onChanged: _sending
                              ? null
                              : (on) => setState(
                                  () => on == true
                                      ? _selected.add(item.id)
                                      : _selected.remove(item.id),
                                ),
                          secondary: ElephantAvatar(
                            name: _titleOf(item),
                            seed: item.id,
                            isGroup: item.isGroup,
                            size: 40,
                          ),
                          title: Text(_titleOf(item)),
                          subtitle: Text(
                            item.isGroup ? 'Group' : '@${item.username ?? ''}',
                          ),
                        );
                      },
                    ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(Insets.page),
                child: PrimaryButton(
                  label: _selected.isEmpty
                      ? 'Choose chats'
                      : 'Send to ${_selected.length}',
                  isLoading: _sending,
                  onPressed: _selected.isEmpty ? null : () => _send(chats),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
