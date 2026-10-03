import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile/controllers/auth_state.dart';
import 'package:mobile/controllers/chat/chat_search_controller.dart';
import 'package:mobile/controllers/chat/group_details_controller.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/models/group.dart';
import 'package:mobile/pages/chat/chat_page.dart';
import 'package:mobile/services/api_services.dart';
import 'package:mobile/services/signal_service.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/ui/avatar.dart';
import 'package:mobile/widgets/ui/components.dart';
import 'package:mobile/widgets/ui/feedback.dart';
import 'package:mobile/widgets/ui/glass.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// What [ChatDetailsPage] pops with. A rename pops the new name as a String.
enum ChatDetailsResult { search, left }

class ChatDetailsPage extends StatefulWidget {
  final bool isGroup;
  final String chatName;
  final String? username;
  final String chatId;

  const ChatDetailsPage({
    super.key,
    required this.isGroup,
    required this.chatName,
    required this.chatId,
    this.username,
  });

  @override
  State<ChatDetailsPage> createState() => _ChatDetailsPageState();
}

class _ChatDetailsPageState extends State<ChatDetailsPage> {
  late String _name = widget.chatName;
  bool? _isVerified;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.isGroup) {
        context.read<GroupDetailsController>().fetchGroupMembers(widget.chatId);
      } else {
        _loadVerification();
      }
    });
  }

  Future<void> _loadVerification() async {
    try {
      final res = await ApiService().getVerification(widget.chatId);
      if (mounted) {
        setState(
          () =>
              _isVerified = ApiService.dataMap(res.data)['is_verified'] == true,
        );
      }
    } catch (_) {
      if (mounted) setState(() => _isVerified = false);
    }
  }

  void _close([Object? result]) {
    Navigator.pop(context, result ?? (_name != widget.chatName ? _name : null));
  }

  // --- Direct chat actions ---

  Future<void> _openSafetyNumber() async {
    final myId = context.read<AuthState>().currentUser?.id;
    if (myId == null) return;

    setState(() => _busy = true);
    final info = await SignalService().getVerification(myId, widget.chatId);
    if (!mounted) return;
    setState(() => _busy = false);

    if (info == null) {
      showSnack(
        context,
        '$_name hasn\'t set up encryption yet.',
        isError: true,
      );
      return;
    }

    final verified = await showGlassSheet<bool>(
      context,
      title: 'Verify safety number',
      builder: (_) => _SafetyNumberSheet(
        name: _name,
        safetyNumber: info.safetyNumber,
        initiallyVerified: info.isVerified,
        contactId: widget.chatId,
      ),
    );
    if (verified != null && mounted) setState(() => _isVerified = verified);
  }

  Future<void> _resetSession() async {
    final confirmed = await confirmAction(
      context,
      title: 'Reset secure session?',
      message:
          'Use this if messages from $_name fail to decrypt, for example after they reinstalled the app. '
          'A new session is created and their current safety number is trusted.',
      confirmLabel: 'Reset',
    );
    if (!confirmed || !mounted) return;

    setState(() => _busy = true);
    final ok = await SignalService().forceResetSession(widget.chatId);
    if (!mounted) return;
    setState(() => _busy = false);
    showSnack(
      context,
      ok
          ? 'Secure session reset. New messages will use it.'
          : 'Couldn\'t reach $_name\'s keys. Try again later.',
      isError: !ok,
    );
    _loadVerification();
  }

  // --- Group actions ---

  Future<void> _rename() async {
    final newName = await promptText(
      context,
      title: 'Rename group',
      initialValue: _name,
      hint: 'Group name',
      maxLength: 100,
    );
    if (newName == null || newName.isEmpty || newName == _name || !mounted) {
      return;
    }

    final error = await context.read<GroupDetailsController>().renameGroup(
      widget.chatId,
      newName,
    );
    if (!mounted) return;
    if (error != null) {
      showSnack(context, error, isError: true);
      return;
    }
    context.read<InboxController>().renameLocal(widget.chatId, newName);
    setState(() => _name = newName);
  }

  Future<void> _leave() async {
    final confirmed = await confirmAction(
      context,
      title: 'Leave $_name?',
      message:
          'You\'ll stop receiving messages from this group. An admin can add you back later.',
      confirmLabel: 'Leave',
      destructive: true,
    );
    if (!confirmed || !mounted) return;

    final groups = context.read<GroupDetailsController>();
    final inbox = context.read<InboxController>();
    final error = await groups.leaveGroup(widget.chatId);
    if (!mounted) return;
    if (error != null) {
      showSnack(context, error, isError: true);
      return;
    }
    await inbox.removeChat(widget.chatId);
    if (mounted) _close(ChatDetailsResult.left);
  }

  Future<void> _memberActions(GroupMember member, bool iAmAdmin) async {
    final myId = context.read<AuthState>().currentUser?.id.toLowerCase();
    final isSelf = member.userId.toLowerCase() == myId;
    if (isSelf) return;

    final action = await showActionSheet<String>(
      context,
      header: ListTile(
        leading: ElephantAvatar(
          name: member.displayName,
          seed: member.userId,
          size: 40,
        ),
        title: Text(member.displayName),
        subtitle: Text('@${member.username}'),
      ),
      actions: [
        const SheetAction(
          icon: Icons.chat_bubble_outline_rounded,
          label: 'Send message',
          value: 'message',
        ),
        if (iAmAdmin)
          SheetAction(
            icon: Icons.person_remove_outlined,
            label: 'Remove from group',
            value: 'remove',
            destructive: true,
          ),
      ],
    );
    if (!mounted || action == null) return;

    if (action == 'message') {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatPage(
            chatUserId: member.userId,
            displayName: member.displayName,
            username: member.username,
          ),
        ),
      );
    } else if (action == 'remove') {
      final confirmed = await confirmAction(
        context,
        title: 'Remove ${member.displayName}?',
        message: 'They will no longer receive messages from $_name.',
        confirmLabel: 'Remove',
        destructive: true,
      );
      if (!confirmed || !mounted) return;
      final error = await context.read<GroupDetailsController>().removeMember(
        widget.chatId,
        member.userId,
      );
      if (mounted) {
        showSnack(
          context,
          error ?? '${member.displayName} was removed',
          isError: error != null,
        );
      }
    }
  }

  // --- Build ---

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: GlassAppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: _close,
          ),
          title: Text(widget.isGroup ? 'Group info' : 'Contact info'),
          actions: [
            if (_busy)
              const Padding(
                padding: EdgeInsets.all(16),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
          ],
        ),
        body: AmbientBackground(
          intensity: 0.7,
          child: ListView(
            padding: EdgeInsets.only(
              top:
                  MediaQuery.paddingOf(context).top +
                  kToolbarHeight +
                  Insets.xl,
              bottom: Insets.xxl + MediaQuery.paddingOf(context).bottom,
            ),
            children: [
              _buildHeader(),
              const SizedBox(height: Insets.xl),
              _buildQuickActions(),
              if (widget.isGroup)
                ..._buildGroupSections()
              else
                ..._buildDirectSections(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final members = context.watch<GroupDetailsController>().currentGroupMembers;
    return Column(
      children: [
        Hero(
          tag: 'avatar-${widget.chatId}',
          child: ElephantAvatar(
            name: _name,
            seed: widget.chatId,
            isGroup: widget.isGroup,
            size: 104,
          ),
        ),
        const SizedBox(height: Insets.lg),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Insets.xl),
          child: Text(
            _name,
            textAlign: TextAlign.center,
            style: context.text.headlineMedium?.copyWith(fontSize: 26),
          ),
        ),
        const SizedBox(height: Insets.xs),
        if (widget.isGroup)
          Text(
            members.isEmpty ? 'Group' : 'Group · ${members.length} members',
            style: context.text.bodyMedium?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          )
        else if (widget.username != null)
          GestureDetector(
            onTap: () {
              Clipboard.setData(ClipboardData(text: widget.username!));
              showSnack(context, 'Username copied');
            },
            child: Text(
              '@${widget.username}',
              style: context.text.bodyMedium?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
          ),
        if (!widget.isGroup && _isVerified == true) ...[
          const SizedBox(height: Insets.sm),
          TagPill(
            'Verified',
            color: context.glass.success,
            icon: Icons.verified_rounded,
          ),
        ],
      ],
    );
  }

  Widget _buildQuickActions() {
    final iAmAdmin =
        widget.isGroup &&
        context.watch<GroupDetailsController>().isAdmin(
          context.read<AuthState>().currentUser?.id,
        );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Insets.page),
      child: Row(
        children: [
          _QuickAction(
            icon: Icons.chat_bubble_outline_rounded,
            label: 'Message',
            onTap: () => _close(),
          ),
          const SizedBox(width: Insets.md),
          _QuickAction(
            icon: Icons.search_rounded,
            label: 'Search',
            onTap: () => _close(ChatDetailsResult.search),
          ),
          if (iAmAdmin) ...[
            const SizedBox(width: Insets.md),
            _QuickAction(
              icon: Icons.person_add_alt_rounded,
              label: 'Add',
              onTap: _openAddMembers,
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _buildDirectSections() {
    return [
      const SectionLabel('Encryption'),
      GlassSection(
        children: [
          ElephantTile(
            icon: Icons.verified_user_outlined,
            iconColor: context.glass.success,
            title: 'Verify safety number',
            subtitle: _isVerified == true
                ? 'You verified $_name\'s keys.'
                : 'Compare numbers with $_name to make sure no one is listening in.',
            trailing: _isVerified == null
                ? null
                : TagPill(
                    _isVerified! ? 'Verified' : 'Not verified',
                    color: _isVerified!
                        ? context.glass.success
                        : context.colors.onSurfaceVariant,
                  ),
            onTap: _openSafetyNumber,
          ),
          ElephantTile(
            icon: Icons.restart_alt_rounded,
            iconColor: context.glass.warning,
            title: 'Reset secure session',
            subtitle: 'Fixes messages that won\'t decrypt.',
            onTap: _resetSession,
          ),
        ],
      ),
      const SectionLabel('About encryption'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Insets.page + 4),
        child: Text(
          'Messages with $_name use the Signal Protocol. Your private keys never leave this device, '
          'so the server only ever sees encrypted text.',
          style: context.text.bodySmall?.copyWith(
            color: context.colors.onSurfaceVariant,
            height: 1.5,
          ),
        ),
      ),
    ];
  }

  List<Widget> _buildGroupSections() {
    final groups = context.watch<GroupDetailsController>();
    final myId = context.read<AuthState>().currentUser?.id.toLowerCase();
    final iAmAdmin = groups.isAdmin(myId);
    final members = groups.currentGroupMembers;

    return [
      if (iAmAdmin) ...[
        const SectionLabel('Settings'),
        GlassSection(
          children: [
            ElephantTile(
              icon: Icons.edit_outlined,
              title: 'Rename group',
              subtitle: _name,
              onTap: _rename,
            ),
          ],
        ),
      ],
      SectionLabel(
        'Members',
        trailing: groups.isLoadingDetails && members.isNotEmpty
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : null,
      ),
      if (members.isEmpty && groups.isLoadingDetails)
        const Padding(
          padding: EdgeInsets.all(Insets.xl),
          child: Center(child: CircularProgressIndicator()),
        )
      else
        GlassSection(
          children: [
            if (iAmAdmin)
              ElephantTile(
                icon: Icons.person_add_alt_rounded,
                title: 'Add members',
                onTap: _openAddMembers,
              ),
            for (final member in members)
              InkWell(
                onTap: () => _memberActions(member, iAmAdmin),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Insets.lg,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      ElephantAvatar(
                        name: member.displayName,
                        seed: member.userId,
                        size: 38,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              member.userId.toLowerCase() == myId
                                  ? '${member.displayName} (you)'
                                  : member.displayName,
                              style: context.text.bodyLarge?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              '@${member.username}',
                              style: context.text.bodySmall?.copyWith(
                                color: context.colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (member.isAdmin) const TagPill('Admin'),
                    ],
                  ),
                ),
              ),
          ],
        ),
      const SectionLabel('Privacy'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Insets.page + 4),
        child: Text(
          'Group messages are encrypted in transit (TLS) but are not end-to-end encrypted yet, '
          'so the server can read them. Use a direct chat for sensitive conversations.',
          style: context.text.bodySmall?.copyWith(
            color: context.colors.onSurfaceVariant,
            height: 1.5,
          ),
        ),
      ),
      const SizedBox(height: Insets.xl),
      GlassSection(
        children: [
          ElephantTile(
            icon: Icons.logout_rounded,
            title: 'Leave group',
            destructive: true,
            showChevron: false,
            onTap: _leave,
          ),
        ],
      ),
    ];
  }

  void _openAddMembers() {
    showGlassSheet(
      context,
      title: 'Add members',
      builder: (_) => _AddMembersSheet(groupId: widget.chatId),
    ).whenComplete(() {
      if (mounted) context.read<ChatSearchController>().clearSearch();
    });
  }
}

class _QuickAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _QuickAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GlassSurface(
        borderRadius: BorderRadius.circular(Radii.lg),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Column(
                children: [
                  Icon(icon, color: context.colors.primary),
                  const SizedBox(height: 6),
                  Text(label, style: context.text.labelLarge),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SafetyNumberSheet extends StatefulWidget {
  final String name;
  final String safetyNumber;
  final bool initiallyVerified;
  final String contactId;

  const _SafetyNumberSheet({
    required this.name,
    required this.safetyNumber,
    required this.initiallyVerified,
    required this.contactId,
  });

  @override
  State<_SafetyNumberSheet> createState() => _SafetyNumberSheetState();
}

class _SafetyNumberSheetState extends State<_SafetyNumberSheet> {
  late bool _verified = widget.initiallyVerified;
  bool _saving = false;

  List<String> get _chunks {
    final digits = widget.safetyNumber.replaceAll(RegExp(r'\s'), '');
    return [
      for (int i = 0; i < digits.length; i += 5)
        digits.substring(i, (i + 5).clamp(0, digits.length)),
    ];
  }

  Future<void> _toggle(bool value) async {
    setState(() => _saving = true);
    try {
      await SignalService().setVerified(widget.contactId, value);
      if (mounted) setState(() => _verified = value);
    } catch (e) {
      if (mounted) {
        showSnack(
          context,
          ApiService.errorMessage(
            e,
            fallback: 'Couldn\'t update verification.',
          ),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fg = context.colors.onSurface;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Insets.xl, 0, Insets.xl, Insets.xl),
      child: Column(
        children: [
          Text(
            'If the numbers on your screen and ${widget.name}\'s screen match, your chat is private.',
            textAlign: TextAlign.center,
            style: context.text.bodyMedium?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Insets.xl),
          GlassSurface(
            borderRadius: BorderRadius.circular(Radii.lg),
            padding: const EdgeInsets.all(Insets.lg),
            child: QrImageView(
              data: widget.safetyNumber.replaceAll(RegExp(r'\s'), ''),
              size: 180,
              eyeStyle: QrEyeStyle(eyeShape: QrEyeShape.circle, color: fg),
              dataModuleStyle: QrDataModuleStyle(
                dataModuleShape: QrDataModuleShape.circle,
                color: fg,
              ),
            ),
          ),
          const SizedBox(height: Insets.xl),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 14,
            runSpacing: 8,
            children: [
              for (final chunk in _chunks)
                Text(
                  chunk,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.5,
                    color: fg,
                  ),
                ),
            ],
          ),
          const SizedBox(height: Insets.lg),
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: widget.safetyNumber));
              showSnack(context, 'Safety number copied');
            },
            icon: const Icon(Icons.copy_rounded, size: 18),
            label: const Text('Copy'),
          ),
          const SizedBox(height: Insets.sm),
          GlassSurface(
            borderRadius: BorderRadius.circular(Radii.md),
            child: SwitchListTile(
              value: _verified,
              onChanged: _saving ? null : _toggle,
              title: const Text('Mark as verified'),
              subtitle: const Text(
                'Resets automatically if their keys change.',
              ),
            ),
          ),
          const SizedBox(height: Insets.lg),
          GradientButton(
            label: 'Done',
            onPressed: () => Navigator.pop(context, _verified),
          ),
        ],
      ),
    );
  }
}

class _AddMembersSheet extends StatefulWidget {
  final String groupId;

  const _AddMembersSheet({required this.groupId});

  @override
  State<_AddMembersSheet> createState() => _AddMembersSheetState();
}

class _AddMembersSheetState extends State<_AddMembersSheet> {
  final _search = TextEditingController();
  Timer? _debounce;
  final Set<String> _adding = {};

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) context.read<ChatSearchController>().queryUsers(value);
    });
  }

  Future<void> _add(String userId, String name) async {
    setState(() => _adding.add(userId));
    final error = await context.read<GroupDetailsController>().addMember(
      widget.groupId,
      userId,
    );
    if (!mounted) return;
    setState(() => _adding.remove(userId));
    showSnack(context, error ?? '$name was added', isError: error != null);
  }

  @override
  Widget build(BuildContext context) {
    final search = context.watch<ChatSearchController>();
    final memberIds = context
        .watch<GroupDetailsController>()
        .currentGroupMembers
        .map((m) => m.userId.toLowerCase())
        .toSet();
    final inbox = context.watch<InboxController>();

    final typed =
        _search.text.trim().length >= ChatSearchController.minQueryLength;
    final candidates = typed
        ? search.results.map((u) => (u.id, u.displayName, u.username)).toList()
        : inbox.inbox
              .where((item) => !item.isGroup)
              .map((item) => (item.id, item.title, item.username ?? ''))
              .toList();

    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.7,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Insets.xl,
              0,
              Insets.xl,
              Insets.sm,
            ),
            child: GlassSearchField(
              controller: _search,
              hint: 'Search by name or username',
              onChanged: (value) {
                setState(() {});
                _onChanged(value);
              },
            ),
          ),
          if (search.isSearchLoading)
            const LinearProgressIndicator(minHeight: 2),
          if (!typed) const SectionLabel('Recent chats'),
          Expanded(
            child: candidates.isEmpty
                ? Center(
                    child: Text(
                      search.error ??
                          (typed
                              ? 'No users found'
                              : 'Search for people to add'),
                      style: TextStyle(color: context.colors.onSurfaceVariant),
                    ),
                  )
                : ListView.builder(
                    itemCount: candidates.length,
                    itemBuilder: (context, index) {
                      final (id, name, username) = candidates[index];
                      final isMember = memberIds.contains(id.toLowerCase());
                      return ListTile(
                        leading: ElephantAvatar(name: name, seed: id, size: 40),
                        title: Text(name),
                        subtitle: Text('@$username'),
                        trailing: isMember
                            ? const TagPill('Member')
                            : _adding.contains(id)
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : IconButton.filledTonal(
                                icon: const Icon(Icons.add_rounded),
                                onPressed: () => _add(id, name),
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
