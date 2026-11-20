import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../controllers/chat/inbox_controller.dart';
import '../../models/chat_folder.dart';
import '../../services/chat_folders.dart';
import '../../themes/app_themes.dart';
import '../../widgets/ui/avatar.dart';
import '../../widgets/ui/components.dart';
import '../../widgets/ui/feedback.dart';
import '../../widgets/ui/surfaces.dart';

/// Opens the editor for [folder], or for a new folder when it is null.
Future<void> editChatFolder(BuildContext context, [ChatFolder? folder]) =>
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ChatFolderEditorPage(folder: folder)),
    );

/// The person's folders, with a way to make more.
class ChatFoldersPage extends StatefulWidget {
  const ChatFoldersPage({super.key});

  @override
  State<ChatFoldersPage> createState() => _ChatFoldersPageState();
}

class _ChatFoldersPageState extends State<ChatFoldersPage> {
  @override
  void initState() {
    super.initState();
    ChatFolders.instance.load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const ElephantAppBar(title: Text('Chat folders')),
      body: ScreenBackground(
        child: ListenableBuilder(
          listenable: ChatFolders.instance,
          builder: (context, _) {
            final folders = ChatFolders.instance.folders;
            final full = folders.length >= ChatFolders.maxFolders;
            return ListView(
              padding: const EdgeInsets.only(top: Insets.lg, bottom: Insets.xl),
              children: [
                if (folders.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: Insets.page,
                      vertical: Insets.lg,
                    ),
                    child: Text(
                      'Folders sort your chats, for example Family or Work. '
                      'They show as tabs above your chats, and only you see them.',
                    ),
                  )
                else
                  Section(
                    children: [
                      for (final folder in folders)
                        ElephantTile(
                          icon: Icons.folder_outlined,
                          title: folder.name,
                          subtitle: folder.chatIds.isEmpty
                              ? 'No chats'
                              : '${folder.chatIds.length} '
                                    '${folder.chatIds.length == 1 ? 'chat' : 'chats'}',
                          onTap: () => editChatFolder(context, folder),
                        ),
                    ],
                  ),
                const SizedBox(height: Insets.lg),
                Section(
                  children: [
                    ElephantTile(
                      icon: Icons.create_new_folder_outlined,
                      title: 'New folder',
                      subtitle: full
                          ? 'You can have up to ${ChatFolders.maxFolders} folders'
                          : null,
                      onTap: full ? null : () => editChatFolder(context),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Make a folder, or change one: its name and which chats it holds.
class ChatFolderEditorPage extends StatefulWidget {
  final ChatFolder? folder;

  const ChatFolderEditorPage({super.key, this.folder});

  @override
  State<ChatFolderEditorPage> createState() => _ChatFolderEditorPageState();
}

class _ChatFolderEditorPageState extends State<ChatFolderEditorPage> {
  late final TextEditingController _name = TextEditingController(
    text: widget.folder?.name ?? '',
  );
  late final Set<String> _chosen = {...?widget.folder?.chatIds};
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final folders = ChatFolders.instance;
    final error = widget.folder == null
        ? await folders.create(_name.text, _chosen)
        : await folders.update(widget.folder!.id, _name.text, _chosen);
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _saving = false;
        _error = error;
      });
      return;
    }
    Navigator.pop(context);
  }

  Future<void> _delete() async {
    final folder = widget.folder!;
    final ok = await confirmAction(
      context,
      title: 'Delete "${folder.name}"?',
      message: 'The chats stay where they are. Only the folder goes.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await ChatFolders.instance.delete(folder.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final chats = context.watch<InboxController>().inbox;
    return Scaffold(
      appBar: ElephantAppBar(
        title: Text(widget.folder == null ? 'New folder' : 'Edit folder'),
        actions: [
          if (widget.folder != null)
            IconButton(
              tooltip: 'Delete folder',
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: _delete,
            ),
          TextButton(
            onPressed: _saving ? null : _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: ScreenBackground(
        child: ListView(
          padding: const EdgeInsets.only(bottom: Insets.xl),
          children: [
            Padding(
              padding: const EdgeInsets.all(Insets.page),
              child: TextField(
                controller: _name,
                maxLength: ChatFolders.maxNameLength,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: 'Folder name',
                  errorText: _error,
                ),
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
              ),
            ),
            const SectionLabel('Chats in this folder'),
            if (chats.isEmpty)
              const Padding(
                padding: EdgeInsets.all(Insets.page),
                child: Text('You have no chats yet.'),
              )
            else
              Section(
                children: [
                  for (final chat in chats)
                    CheckboxListTile(
                      key: ValueKey('pick-${chat.id}'),
                      value: _chosen.contains(chat.id.toLowerCase()),
                      onChanged: (on) => setState(() {
                        final id = chat.id.toLowerCase();
                        on == true ? _chosen.add(id) : _chosen.remove(id);
                      }),
                      secondary: ElephantAvatar(
                        name: chat.title,
                        seed: chat.id,
                        isGroup: chat.isGroup,
                        size: 40,
                      ),
                      title: Text(
                        chat.title.isEmpty
                            ? (chat.username ?? 'Unknown')
                            : chat.title,
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
