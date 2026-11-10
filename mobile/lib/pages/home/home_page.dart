import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile/controllers/auth_state.dart';
import 'package:mobile/controllers/chat/chat_connection_controller.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/models/inbox_item.dart';
import 'package:mobile/pages/chat/chat_details_page.dart';
import 'package:mobile/pages/chat/chat_page.dart';
import 'package:mobile/pages/new%20chat/new_chat_page.dart';
import 'package:mobile/pages/new%20chat/select_contact_page.dart';
import 'package:mobile/pages/settings/settings_page.dart';
import 'package:mobile/services/push/push_service.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/home_page_widgets.dart';
import 'package:mobile/widgets/ui/components.dart';
import 'package:mobile/widgets/ui/feedback.dart';
import 'package:mobile/widgets/ui/surfaces.dart';
import 'package:provider/provider.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;
  late final InboxController _inbox = context.read<InboxController>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _maybeShowNewUsername(),
    );
    // A tapped notification asks for a chat. The inbox may still be loading
    // (when the tap started the app), so also try again as it changes.
    PushService.instance.chatToOpen.addListener(_openRequestedChat);
    _inbox.addListener(_openRequestedChat);
    WidgetsBinding.instance.addPostFrameCallback((_) => _openRequestedChat());
  }

  @override
  void dispose() {
    PushService.instance.chatToOpen.removeListener(_openRequestedChat);
    _inbox.removeListener(_openRequestedChat);
    super.dispose();
  }

  void _openRequestedChat() {
    final id = PushService.instance.chatToOpen.value;
    if (id == null || !mounted) return;

    final chat = _inbox.inbox.where((item) => item.id == id).firstOrNull;
    if (chat == null) return; // not loaded yet
    PushService.instance.chatToOpen.value = null;
    openConversation(context, chat);
  }

  /// Registration assigns a discriminator; make sure the user sees it once.
  void _maybeShowNewUsername() {
    final auth = context.read<AuthState>();
    final username = auth.newlyRegisteredUsername;
    if (username == null || !mounted) return;
    auth.newlyRegisteredUsername = null;

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(
          Icons.celebration_rounded,
          color: dialogContext.colors.primary,
          size: 36,
        ),
        title: const Text('Welcome to Elephant'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'This is your username. You\'ll need it to sign in, and friends use it to find you.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Insets.lg),
            Panel(
              borderRadius: BorderRadius.circular(Radii.md),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('@$username', style: dialogContext.text.titleMedium),
                  const SizedBox(width: 8),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: username));
                      showSnack(context, 'Username copied');
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final inbox = context.watch<InboxController>();

    return Scaffold(
      body: ScreenBackground(
        child: IndexedStack(
          index: _tab,
          children: const [
            _ChatsTab(),
            _GroupsTab(),
            SettingsPage(embedded: true),
          ],
        ),
      ),
      // An empty list shows its own button for the same action, which the
      // floating one would cover.
      floatingActionButton:
          _tab == 2 || (_tab == 0 ? inbox.inbox : inbox.groups).isEmpty
          ? null
          : Padding(
              padding: const EdgeInsets.only(bottom: Insets.sm),
              child: _ComposeButton(
                icon: _tab == 0 ? Icons.edit_rounded : Icons.group_add_rounded,
                tooltip: _tab == 0 ? 'New message' : 'New group',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => _tab == 0
                        ? const NewChatPage()
                        : const SelectContactPage(),
                  ),
                ),
              ),
            ),
      bottomNavigationBar: _NavBar(
        index: _tab,
        unreadChats: inbox.unreadChats,
        onChanged: (i) {
          if (i != _tab) HapticFeedback.selectionClick();
          setState(() => _tab = i);
        },
      ),
    );
  }
}

void openConversation(BuildContext context, InboxItem item) {
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => ChatPage(
        chatUserId: item.id,
        displayName: item.title.isEmpty ? (item.username ?? '') : item.title,
        username: item.username,
        isGroup: item.isGroup,
      ),
    ),
  );
}

Future<void> _showConversationActions(
  BuildContext context,
  InboxItem item,
) async {
  final action = await showActionSheet<String>(
    context,
    header: ListTile(
      title: Text(item.title, style: context.text.titleMedium),
      subtitle: Text(item.isGroup ? 'Group' : '@${item.username ?? ''}'),
    ),
    actions: [
      const SheetAction(
        icon: Icons.chat_bubble_outline_rounded,
        label: 'Open chat',
        value: 'open',
      ),
      if (item.unreadCount > 0)
        const SheetAction(
          icon: Icons.mark_chat_read_outlined,
          label: 'Mark as read',
          value: 'read',
        ),
      SheetAction(
        icon: item.isGroup
            ? Icons.info_outline_rounded
            : Icons.verified_user_outlined,
        label: item.isGroup ? 'Group info' : 'Contact & encryption',
        value: 'info',
      ),
    ],
  );
  if (!context.mounted || action == null) return;

  switch (action) {
    case 'open':
      openConversation(context, item);
      break;
    case 'read':
      await context.read<InboxController>().markReadFor(item);
      break;
    case 'info':
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatDetailsPage(
            chatId: item.id,
            chatName: item.title,
            username: item.username,
            isGroup: item.isGroup,
          ),
        ),
      );
      break;
  }
}

class _ChatsTab extends StatefulWidget {
  const _ChatsTab();

  @override
  State<_ChatsTab> createState() => _ChatsTabState();
}

class _ChatsTabState extends State<_ChatsTab> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final inbox = context.watch<InboxController>();
    final connection = context.watch<ChatConnectionController>();

    final query = _query.toLowerCase();
    final items = query.isEmpty
        ? inbox.inbox
        : inbox.inbox.where((item) {
            return item.title.toLowerCase().contains(query) ||
                (item.username?.toLowerCase().contains(query) ?? false) ||
                item.lastMessage.toLowerCase().contains(query);
          }).toList();

    return RefreshIndicator(
      edgeOffset: 120,
      onRefresh: () => inbox.loadInbox(),
      child: CustomScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        slivers: [
          _HomeHeader(
            title: 'Chats',
            actions: [
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_horiz_rounded),
                onSelected: (value) async {
                  if (value == 'read') {
                    await inbox.markAllRead();
                    if (context.mounted) {
                      showSnack(context, 'All chats marked as read');
                    }
                  } else if (value == 'group') {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const SelectContactPage(),
                      ),
                    );
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'read',
                    enabled: inbox.unreadChats > 0,
                    child: const Text('Mark all as read'),
                  ),
                  const PopupMenuItem(value: 'group', child: Text('New group')),
                ],
              ),
            ],
          ),
          SliverToBoxAdapter(
            child: _ConnectionBanner(
              status: connection.status,
              onRetry: connection.retryNow,
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                Insets.page,
                Insets.xs,
                Insets.page,
                Insets.sm,
              ),
              child: SearchField(
                controller: _searchController,
                hint: 'Search chats',
                onChanged: (value) => setState(() => _query = value.trim()),
              ),
            ),
          ),
          if (items.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: !inbox.hasLoadedOnce && inbox.isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : query.isNotEmpty
                  ? EmptyState(
                      icon: Icons.search_off_rounded,
                      title: 'No matches',
                      message: 'No chat matches "$_query".',
                    )
                  : inbox.loadError != null
                  ? EmptyState(
                      icon: Icons.cloud_off_rounded,
                      title: 'Couldn\'t load chats',
                      message: inbox.loadError!,
                      actionLabel: 'Try again',
                      onAction: () => inbox.loadInbox(),
                    )
                  : EmptyState(
                      icon: Icons.forum_rounded,
                      title: 'No conversations yet',
                      message:
                          'Find someone by their username and say hello. Direct messages are end-to-end encrypted.',
                      actionLabel: 'Start a chat',
                      onAction: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const NewChatPage()),
                      ),
                    ),
            )
          else
            SliverList.builder(
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                return ConversationTile(
                  key: ValueKey(item.id),
                  conversation: item,
                  onTap: () => openConversation(context, item),
                  onLongPress: () {
                    HapticFeedback.mediumImpact();
                    _showConversationActions(context, item);
                  },
                );
              },
            ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 88)),
        ],
      ),
    );
  }
}

class _GroupsTab extends StatelessWidget {
  const _GroupsTab();

  @override
  Widget build(BuildContext context) {
    final inbox = context.watch<InboxController>();
    final groups = inbox.groups;

    return RefreshIndicator(
      edgeOffset: 120,
      onRefresh: () => inbox.loadInbox(),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        slivers: [
          const _HomeHeader(title: 'Groups'),
          if (groups.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                icon: Icons.groups_rounded,
                title: 'No groups yet',
                message:
                    'Create a group to talk with several people at once. Group messages are not end-to-end encrypted yet.',
                actionLabel: 'Create a group',
                onAction: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SelectContactPage()),
                ),
              ),
            )
          else ...[
            SliverToBoxAdapter(
              child: SectionLabel(
                '${groups.length} ${groups.length == 1 ? 'group' : 'groups'}',
              ),
            ),
            SliverList.builder(
              itemCount: groups.length,
              itemBuilder: (context, index) {
                final item = groups[index];
                return ConversationTile(
                  key: ValueKey(item.id),
                  conversation: item,
                  onTap: () => openConversation(context, item),
                  onLongPress: () => _showConversationActions(context, item),
                );
              },
            ),
          ],
          const SliverPadding(padding: EdgeInsets.only(bottom: 88)),
        ],
      ),
    );
  }
}

/// Large title that collapses into a plain bar on scroll.
class _HomeHeader extends StatelessWidget {
  final String title;
  final List<Widget>? actions;

  const _HomeHeader({required this.title, this.actions});

  @override
  Widget build(BuildContext context) {
    return SliverAppBar(
      pinned: true,
      expandedHeight: 104,
      backgroundColor: Colors.transparent,
      actions: [
        ...?actions,
        const SizedBox(width: Insets.sm),
      ],
      flexibleSpace: Stack(
        fit: StackFit.expand,
        children: [
          const HeaderBackground(),
          FlexibleSpaceBar(
            titlePadding: const EdgeInsetsDirectional.only(
              start: Insets.page,
              bottom: 14,
            ),
            expandedTitleScale: 1.55,
            title: Text(
              title,
              style: context.text.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectionBanner extends StatelessWidget {
  final ConnectionStatus status;
  final VoidCallback onRetry;

  const _ConnectionBanner({required this.status, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final visible = status != ConnectionStatus.connected;
    final isOffline = status == ConnectionStatus.offline;
    final color = isOffline ? context.colors.error : context.tokens.warning;

    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      child: !visible
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.fromLTRB(
                Insets.page,
                Insets.xs,
                Insets.page,
                Insets.sm,
              ),
              child: Panel(
                borderRadius: BorderRadius.circular(Radii.md),
                tint: color.withValues(alpha: 0.12),
                padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
                child: Row(
                  children: [
                    if (isOffline)
                      Icon(Icons.cloud_off_rounded, size: 18, color: color)
                    else
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: color,
                        ),
                      ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        isOffline
                            ? 'You\'re offline. Messages will send when you reconnect.'
                            : 'Connecting…',
                        style: context.text.bodyMedium?.copyWith(
                          color: color,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (!isOffline)
                      TextButton(onPressed: onRetry, child: const Text('Retry'))
                    else
                      const SizedBox(height: 40),
                  ],
                ),
              ),
            ),
    );
  }
}

class _ComposeButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _ComposeButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton(
      tooltip: tooltip,
      onPressed: onTap,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        child: Icon(icon, key: ValueKey(icon), size: 24),
      ),
    );
  }
}

class _NavBar extends StatelessWidget {
  final int index;
  final int unreadChats;
  final ValueChanged<int> onChanged;

  const _NavBar({
    required this.index,
    required this.unreadChats,
    required this.onChanged,
  });

  static const _items = [
    (Icons.chat_bubble_outline_rounded, Icons.chat_bubble_rounded, 'Chats'),
    (Icons.groups_outlined, Icons.groups_rounded, 'Groups'),
    (Icons.person_outline_rounded, Icons.person_rounded, 'You'),
  ];

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: context.tokens.hairline)),
      ),
      child: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: onChanged,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        destinations: [
          for (int i = 0; i < _items.length; i++)
            NavigationDestination(
              label: _items[i].$3,
              icon: _icon(context, i, _items[i].$1),
              selectedIcon: _icon(context, i, _items[i].$2),
            ),
        ],
      ),
    );
  }

  Widget _icon(BuildContext context, int i, IconData icon) {
    return Badge(
      isLabelVisible: i == 0 && unreadChats > 0,
      label: Text('$unreadChats'),
      backgroundColor: context.colors.primary,
      textColor: context.tokens.onAccent,
      child: Icon(icon),
    );
  }
}
