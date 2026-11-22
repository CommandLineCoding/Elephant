import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mobile/controllers/chat/chat_search_controller.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/models/broadcast_list.dart';
import 'package:mobile/pages/broadcast/broadcast_page.dart';
import 'package:mobile/pages/chat/chat_page.dart';
import 'package:mobile/providers/group_controller_provider.dart';
import 'package:mobile/services/broadcast_lists.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/ui/avatar.dart';
import 'package:mobile/widgets/ui/components.dart';
import 'package:mobile/widgets/ui/feedback.dart';
import 'package:mobile/widgets/ui/surfaces.dart';
import 'package:provider/provider.dart';

/// Step 1 of creating a group: pick members, then name the group. Also picks
/// the people for a broadcast list ([forBroadcast], or [editing] one).
class SelectContactPage extends StatefulWidget {
  final bool forBroadcast;
  final BroadcastList? editing;

  const SelectContactPage({super.key, this.forBroadcast = false, this.editing});

  bool get isBroadcast => forBroadcast || editing != null;

  @override
  State<SelectContactPage> createState() => _SelectContactPageState();
}

typedef _Contact = ({String name, String username});

class _SelectContactPageState extends State<SelectContactPage> {
  final Map<String, _Contact> _selected = {};
  final _searchController = TextEditingController();
  Timer? _debounce;
  late final ChatSearchController _search = context
      .read<ChatSearchController>();

  @override
  void initState() {
    super.initState();
    for (final m in widget.editing?.members ?? const <BroadcastMember>[]) {
      _selected[m.id] = (name: m.name, username: '');
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _search.clearSearch());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    Future.microtask(_search.clearSearch);
    super.dispose();
  }

  void _onChanged(String value) {
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 350),
      () => _search.queryUsers(value),
    );
  }

  void _toggle(String id, String name, String username) {
    setState(() {
      if (_selected.remove(id) == null) {
        _selected[id] = (name: name, username: username);
      }
    });
  }

  void _next() {
    if (widget.isBroadcast) {
      showSheet<bool>(
        context,
        title: widget.editing == null ? 'Name your list' : 'Edit list',
        builder: (_) => _BroadcastSheet(
          members: [
            for (final e in _selected.entries)
              BroadcastMember(id: e.key, name: e.value.name),
          ],
          editing: widget.editing,
        ),
      );
      return;
    }
    showSheet<bool>(
      context,
      title: 'Name your group',
      builder: (_) => _CreateGroupSheet(members: Map.of(_selected)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final search = context.watch<ChatSearchController>();
    final inbox = context.watch<InboxController>();
    final query = _searchController.text.trim();
    final typed = query.length >= ChatSearchController.minQueryLength;

    final List<(String, String, String)> people = typed
        ? search.results.map((u) => (u.id, u.displayName, u.username)).toList()
        : inbox.inbox
              .where((t) => !t.isGroup)
              .map((t) => (t.id, t.title, t.username ?? ''))
              .toList();

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: ElephantAppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.editing != null
                  ? 'Edit list'
                  : widget.forBroadcast
                  ? 'New broadcast'
                  : 'New group',
            ),
            Text(
              _selected.isEmpty
                  ? (widget.isBroadcast ? 'Pick people' : 'Add members')
                  : '${_selected.length} selected',
              style: context.text.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: AnimatedScale(
        scale: _selected.isEmpty ? 0 : 1,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutBack,
        child: FloatingActionButton.extended(
          onPressed: _selected.isEmpty ? null : _next,
          icon: const Icon(Icons.arrow_forward_rounded),
          label: const Text('Next'),
        ),
      ),
      body: ScreenBackground(
        child: Column(
          children: [
            SizedBox(
              height:
                  MediaQuery.paddingOf(context).top +
                  kToolbarHeight +
                  Insets.md,
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              child: _selected.isEmpty
                  ? const SizedBox(width: double.infinity)
                  : SizedBox(
                      height: 92,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(
                          horizontal: Insets.page,
                        ),
                        children: [
                          for (final entry in _selected.entries)
                            Padding(
                              padding: const EdgeInsets.only(right: Insets.md),
                              child: GestureDetector(
                                onTap: () => _toggle(
                                  entry.key,
                                  entry.value.name,
                                  entry.value.username,
                                ),
                                child: SizedBox(
                                  width: 62,
                                  child: Column(
                                    children: [
                                      Stack(
                                        clipBehavior: Clip.none,
                                        children: [
                                          ElephantAvatar(
                                            name: entry.value.name,
                                            seed: entry.key,
                                            size: 52,
                                          ),
                                          Positioned(
                                            right: -4,
                                            top: -4,
                                            child: CircleAvatar(
                                              radius: 10,
                                              backgroundColor:
                                                  context.colors.onSurface,
                                              child: Icon(
                                                Icons.close_rounded,
                                                size: 13,
                                                color: context.colors.surface,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        entry.value.name.split(' ').first,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: context.text.bodySmall?.copyWith(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.page),
              child: SearchField(
                controller: _searchController,
                hint: 'Search name or username',
                onChanged: _onChanged,
              ),
            ),
            if (search.isSearchLoading)
              const Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: Insets.page,
                  vertical: Insets.sm,
                ),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            if (!typed && people.isNotEmpty) const SectionLabel('Recent chats'),
            Expanded(
              child: people.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(Insets.xxl),
                      child: Text(
                        search.error ??
                            (typed
                                ? 'No one found.'
                                : 'Search for people by name or username to add them.'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: context.colors.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: EdgeInsets.only(
                        bottom: 100 + MediaQuery.paddingOf(context).bottom,
                      ),
                      itemCount: people.length,
                      itemBuilder: (context, index) {
                        final (id, name, username) = people[index];
                        final selected = _selected.containsKey(id);
                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: Insets.page,
                            vertical: 2,
                          ),
                          leading: ElephantAvatar(
                            name: name,
                            seed: id,
                            size: 46,
                            showSelected: selected,
                          ),
                          title: Text(name),
                          subtitle: Text('@$username'),
                          // The row is the tap target; the box only shows it.
                          trailing: ExcludeSemantics(
                            child: Checkbox(
                              value: selected,
                              shape: const CircleBorder(),
                              onChanged: (_) => _toggle(id, name, username),
                            ),
                          ),
                          selected: selected,
                          onTap: () => _toggle(id, name, username),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CreateGroupSheet extends StatefulWidget {
  final Map<String, _Contact> members;

  const _CreateGroupSheet({required this.members});

  @override
  State<_CreateGroupSheet> createState() => _CreateGroupSheetState();
}

class _CreateGroupSheetState extends State<_CreateGroupSheet> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;

    final groups = context.read<GroupController>();
    final inbox = context.read<InboxController>();
    final navigator = Navigator.of(context);

    final group = await groups.createGroup(
      groupName: name,
      memberIds: widget.members.keys.toList(),
    );
    if (!mounted) return;

    if (group == null) {
      showSnack(
        context,
        groups.lastError ?? 'Couldn\'t create the group.',
        isError: true,
      );
      return;
    }

    unawaited(inbox.loadInbox());
    navigator.pop(true);
    navigator.pushReplacement(
      MaterialPageRoute(
        builder: (_) => ChatPage(
          chatUserId: group.id,
          displayName: group.name,
          isGroup: true,
        ),
      ),
    );
    if (groups.failedMemberIds.isNotEmpty) {
      showSnack(
        navigator.context,
        '${groups.failedMemberIds.length} member(s) couldn\'t be added. Try again from group info.',
        isError: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLoading = context.watch<GroupController>().isLoading;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.xl,
        Insets.sm,
        Insets.xl,
        Insets.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ValueListenableBuilder(
                valueListenable: _name,
                builder: (_, value, _) => ElephantAvatar(
                  name: value.text,
                  seed: value.text.isEmpty ? 'new-group' : value.text,
                  isGroup: true,
                  size: 56,
                ),
              ),
              const SizedBox(width: Insets.lg),
              Expanded(
                child: TextField(
                  controller: _name,
                  autofocus: true,
                  maxLength: 100,
                  textCapitalization: TextCapitalization.sentences,
                  onSubmitted: (_) => _create(),
                  decoration: const InputDecoration(
                    hintText: 'Group name',
                    counterText: '',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Insets.lg),
          Text(
            '${widget.members.length + 1} members including you. Group messages are not end-to-end encrypted yet.',
            style: context.text.bodySmall?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Insets.xl),
          ValueListenableBuilder(
            valueListenable: _name,
            builder: (_, value, _) => PrimaryButton(
              label: 'Create group',
              icon: Icons.check_rounded,
              isLoading: isLoading,
              onPressed: value.text.trim().isEmpty ? null : _create,
            ),
          ),
        ],
      ),
    );
  }
}

/// Names a broadcast list and saves it, or saves the changes to one.
class _BroadcastSheet extends StatefulWidget {
  final List<BroadcastMember> members;
  final BroadcastList? editing;

  const _BroadcastSheet({required this.members, this.editing});

  @override
  State<_BroadcastSheet> createState() => _BroadcastSheetState();
}

class _BroadcastSheetState extends State<_BroadcastSheet> {
  late final _name = TextEditingController(text: widget.editing?.name ?? '');
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final lists = BroadcastLists.instance;
    final navigator = Navigator.of(context);
    setState(() => _saving = true);
    final editing = widget.editing;
    String? error;
    BroadcastList? made;
    if (editing == null) {
      (made, error) = await lists.create(_name.text, widget.members);
    } else {
      error = await lists.update(editing.id, _name.text, widget.members);
    }
    if (!mounted) return;
    if (error != null) {
      setState(() => _saving = false);
      showSnack(context, error, isError: true);
      return;
    }
    // Close the sheet and the picker.
    navigator.pop(true);
    navigator.pop();
    if (made != null) {
      navigator.push(
        MaterialPageRoute(builder: (_) => BroadcastPage(listId: made!.id)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.xl,
        Insets.sm,
        Insets.xl,
        Insets.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            maxLength: BroadcastLists.maxNameLength,
            textCapitalization: TextCapitalization.sentences,
            onSubmitted: (_) => _save(),
            decoration: const InputDecoration(
              hintText: 'List name',
              counterText: '',
            ),
          ),
          const SizedBox(height: Insets.lg),
          Text(
            '${widget.members.length} '
            '${widget.members.length == 1 ? 'person' : 'people'}. A message to '
            'the list goes to each of them on their own, end-to-end encrypted. '
            'They can\'t see each other, and their replies come back in your '
            'chat with them.',
            style: context.text.bodySmall?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Insets.xl),
          ValueListenableBuilder(
            valueListenable: _name,
            builder: (_, value, _) => PrimaryButton(
              label: widget.editing == null ? 'Create list' : 'Save',
              icon: Icons.check_rounded,
              isLoading: _saving,
              onPressed: value.text.trim().isEmpty ? null : _save,
            ),
          ),
        ],
      ),
    );
  }
}
