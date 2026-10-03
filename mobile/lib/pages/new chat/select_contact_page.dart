import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mobile/controllers/chat/chat_search_controller.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/pages/chat/chat_page.dart';
import 'package:mobile/providers/group_controller_provider.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/ui/avatar.dart';
import 'package:mobile/widgets/ui/components.dart';
import 'package:mobile/widgets/ui/feedback.dart';
import 'package:mobile/widgets/ui/glass.dart';
import 'package:provider/provider.dart';

/// Step 1 of creating a group: pick members, then name the group.
class SelectContactPage extends StatefulWidget {
  const SelectContactPage({super.key});

  @override
  State<SelectContactPage> createState() => _SelectContactPageState();
}

typedef _Contact = ({String name, String username});

class _SelectContactPageState extends State<SelectContactPage> {
  final Map<String, _Contact> _selected = {};
  final _searchController = TextEditingController();
  Timer? _debounce;
  late final ChatSearchController _search = context.read<ChatSearchController>();

  @override
  void initState() {
    super.initState();
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
    _debounce = Timer(const Duration(milliseconds: 350), () => _search.queryUsers(value));
  }

  void _toggle(String id, String name, String username) {
    setState(() {
      if (_selected.remove(id) == null) {
        _selected[id] = (name: name, username: username);
      }
    });
  }

  void _next() {
    showGlassSheet<bool>(
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
      appBar: GlassAppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('New group'),
            Text(
              _selected.isEmpty ? 'Add members' : '${_selected.length} selected',
              style: context.text.bodySmall?.copyWith(color: context.colors.onSurfaceVariant),
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
      body: AmbientBackground(
        intensity: 0.5,
        child: Column(
          children: [
            SizedBox(height: MediaQuery.paddingOf(context).top + kToolbarHeight + Insets.md),
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              child: _selected.isEmpty
                  ? const SizedBox(width: double.infinity)
                  : SizedBox(
                      height: 92,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: Insets.page),
                        children: [
                          for (final entry in _selected.entries)
                            Padding(
                              padding: const EdgeInsets.only(right: Insets.md),
                              child: GestureDetector(
                                onTap: () => _toggle(entry.key, entry.value.name, entry.value.username),
                                child: SizedBox(
                                  width: 62,
                                  child: Column(
                                    children: [
                                      Stack(
                                        clipBehavior: Clip.none,
                                        children: [
                                          ElephantAvatar(name: entry.value.name, seed: entry.key, size: 52),
                                          Positioned(
                                            right: -4,
                                            top: -4,
                                            child: CircleAvatar(
                                              radius: 10,
                                              backgroundColor: context.colors.onSurface,
                                              child: Icon(Icons.close_rounded, size: 13, color: context.colors.surface),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        entry.value.name.split(' ').first,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: context.text.bodySmall?.copyWith(fontWeight: FontWeight.w600),
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
              child: GlassSearchField(
                controller: _searchController,
                hint: 'Search name or username',
                onChanged: _onChanged,
              ),
            ),
            if (search.isSearchLoading)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: Insets.page, vertical: Insets.sm),
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
                        style: TextStyle(color: context.colors.onSurfaceVariant),
                      ),
                    )
                  : ListView.builder(
                      padding: EdgeInsets.only(bottom: 100 + MediaQuery.paddingOf(context).bottom),
                      itemCount: people.length,
                      itemBuilder: (context, index) {
                        final (id, name, username) = people[index];
                        final selected = _selected.containsKey(id);
                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: Insets.page, vertical: 2),
                          leading: ElephantAvatar(name: name, seed: id, size: 46, showSelected: selected),
                          title: Text(name),
                          subtitle: Text('@$username'),
                          trailing: Checkbox(
                            value: selected,
                            shape: const CircleBorder(),
                            onChanged: (_) => _toggle(id, name, username),
                          ),
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

    final group = await groups.createGroup(groupName: name, memberIds: widget.members.keys.toList());
    if (!mounted) return;

    if (group == null) {
      showSnack(context, groups.lastError ?? 'Couldn\'t create the group.', isError: true);
      return;
    }

    unawaited(inbox.loadInbox());
    navigator.pop(true);
    navigator.pushReplacement(
      MaterialPageRoute(
        builder: (_) => ChatPage(chatUserId: group.id, displayName: group.name, isGroup: true),
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
      padding: const EdgeInsets.fromLTRB(Insets.xl, Insets.sm, Insets.xl, Insets.xl),
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
                  decoration: const InputDecoration(hintText: 'Group name', counterText: ''),
                ),
              ),
            ],
          ),
          const SizedBox(height: Insets.lg),
          Text(
            '${widget.members.length + 1} members including you. Group messages are not end-to-end encrypted yet.',
            style: context.text.bodySmall?.copyWith(color: context.colors.onSurfaceVariant),
          ),
          const SizedBox(height: Insets.xl),
          ValueListenableBuilder(
            valueListenable: _name,
            builder: (_, value, _) => GradientButton(
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
