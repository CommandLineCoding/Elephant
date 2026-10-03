import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mobile/controllers/chat/chat_search_controller.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/models/user.dart';
import 'package:mobile/pages/new%20chat/select_contact_page.dart';
import 'package:mobile/pages/settings/settings_page.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/ui/avatar.dart';
import 'package:mobile/widgets/ui/components.dart';
import 'package:mobile/widgets/ui/glass.dart';
import 'package:provider/provider.dart';
import '../chat/chat_page.dart';

class NewChatPage extends StatefulWidget {
  const NewChatPage({super.key});

  @override
  State<NewChatPage> createState() => _NewChatPageState();
}

class _NewChatPageState extends State<NewChatPage> {
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

  void _open(String id, String name, String? username) {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => ChatPage(chatUserId: id, displayName: name, username: username),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final search = context.watch<ChatSearchController>();
    final inbox = context.watch<InboxController>();
    final query = _searchController.text.trim();
    final isSearching = query.isNotEmpty;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassAppBar(
        title: const Text('New message'),
        actions: [
          IconButton(
            tooltip: 'My QR code',
            icon: const Icon(Icons.qr_code_rounded),
            onPressed: () => showUserCard(context),
          ),
          const SizedBox(width: Insets.xs),
        ],
      ),
      body: AmbientBackground(
        intensity: 0.5,
        child: Column(
          children: [
            SizedBox(height: MediaQuery.paddingOf(context).top + kToolbarHeight + Insets.md),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.page),
              child: GlassSearchField(
                controller: _searchController,
                hint: 'Search name or username',
                autofocus: true,
                onChanged: _onChanged,
              ),
            ),
            if (search.isSearchLoading)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: Insets.page, vertical: Insets.sm),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            Expanded(
              child: isSearching ? _buildResults(search, query) : _buildIdle(inbox),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildIdle(InboxController inbox) {
    final recents = inbox.inbox.where((t) => !t.isGroup).toList();
    return ListView(
      padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom + Insets.xl),
      children: [
        const SizedBox(height: Insets.lg),
        GlassSection(
          children: [
            ElephantTile(
              icon: Icons.group_add_rounded,
              title: 'New group',
              subtitle: 'Chat with several people at once',
              onTap: () => Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (_) => const SelectContactPage()),
              ),
            ),
          ],
        ),
        if (recents.isNotEmpty) ...[
          const SectionLabel('Recent'),
          for (final thread in recents)
            _PersonTile(
              id: thread.id,
              name: thread.title,
              username: thread.username,
              onTap: () => _open(thread.id, thread.title, thread.username),
            ),
        ] else
          Padding(
            padding: const EdgeInsets.all(Insets.xxl),
            child: Text(
              'Search for someone by their username, like alex.4821, to start an encrypted chat.',
              textAlign: TextAlign.center,
              style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant),
            ),
          ),
      ],
    );
  }

  Widget _buildResults(ChatSearchController search, String query) {
    if (query.length < ChatSearchController.minQueryLength) {
      return _hint('Keep typing…');
    }
    if (search.error != null) return _hint(search.error!);
    if (!search.isSearchLoading && search.results.isEmpty) {
      return const EmptyState(
        icon: Icons.person_search_rounded,
        title: 'No one found',
        message: 'Check the spelling, or ask them for their full username.',
      );
    }

    final List<UserModel> users = search.results;
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.extentAfter < 200) search.loadMore();
        return false;
      },
      child: ListView.builder(
        padding: EdgeInsets.only(top: Insets.sm, bottom: MediaQuery.paddingOf(context).bottom + Insets.xl),
        itemCount: users.length + (search.isLoadingMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index == users.length) {
            return const Padding(
              padding: EdgeInsets.all(Insets.lg),
              child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
            );
          }
          final user = users[index];
          return _PersonTile(
            id: user.id,
            name: user.displayName,
            username: user.username,
            onTap: () => _open(user.id, user.displayName, user.username),
          );
        },
      ),
    );
  }

  Widget _hint(String text) {
    return Padding(
      padding: const EdgeInsets.all(Insets.xxl),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant),
      ),
    );
  }
}

class _PersonTile extends StatelessWidget {
  final String id;
  final String name;
  final String? username;
  final VoidCallback onTap;

  const _PersonTile({
    required this.id,
    required this.name,
    required this.username,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: Insets.page, vertical: 2),
      leading: ElephantAvatar(name: name, seed: id, size: 46),
      title: Text(name),
      subtitle: username != null ? Text('@$username') : null,
      onTap: onTap,
    );
  }
}
