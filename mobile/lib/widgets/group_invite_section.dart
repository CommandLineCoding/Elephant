import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile/controllers/chat/group_details_controller.dart';
import 'package:mobile/core/invite_links.dart';
import 'package:mobile/services/api_services.dart';
import 'package:mobile/services/group_invites.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/ui/components.dart';
import 'package:mobile/widgets/ui/feedback.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

/// For a group's admins: the invite link (create, copy, share, reset, turn off,
/// require approval) and the people waiting to be let in.
class GroupInviteSection extends StatefulWidget {
  final String groupId;
  final GroupInvitesApi api;

  /// Opens the system's share sheet with [text]. Replaced in tests.
  final Future<void> Function(String text) share;

  const GroupInviteSection({
    super.key,
    required this.groupId,
    this.api = const ServerGroupInvitesApi(),
    this.share = _share,
  });

  static Future<void> _share(String text) async {
    await SharePlus.instance.share(ShareParams(text: text));
  }

  @override
  State<GroupInviteSection> createState() => _GroupInviteSectionState();
}

class _GroupInviteSectionState extends State<GroupInviteSection> {
  GroupInvite? _invite;
  List<JoinRequest> _requests = const [];
  bool _busy = false;
  GroupDetailsController? _groups;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // An admin changing the group, or someone asking to join, tells the group's
    // members; look at the waiting list again then.
    final groups = context.read<GroupDetailsController>();
    if (groups != _groups) {
      _groups?.removeListener(_loadRequests);
      _groups = groups..addListener(_loadRequests);
    }
  }

  @override
  void dispose() {
    _groups?.removeListener(_loadRequests);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final invite = await widget.api.get(widget.groupId);
      if (mounted) setState(() => _invite = invite);
      if (invite.requireApproval) await _loadRequests();
    } catch (e) {
      debugPrint("Couldn't load the invite link: $e");
    }
  }

  Future<void> _loadRequests() async {
    if (_invite?.requireApproval != true) return;
    try {
      final list = await widget.api.requests(widget.groupId);
      if (mounted) setState(() => _requests = list);
    } catch (e) {
      debugPrint("Couldn't load join requests: $e");
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) {
        showSnack(
          context,
          ApiService.errorMessage(e, fallback: 'Couldn\'t do that.'),
          isError: true,
        );
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _create() => _run(() async {
    final invite = await widget.api.set(widget.groupId);
    if (mounted) setState(() => _invite = invite);
  });

  Future<void> _setApproval(bool on) => _run(() async {
    final invite = await widget.api.set(widget.groupId, requireApproval: on);
    if (!mounted) return;
    setState(() => _invite = invite);
    await _loadRequests();
  });

  Future<void> _reset() async {
    final ok = await confirmAction(
      context,
      title: 'Reset the link?',
      message:
          'The old link stops working at once. Anyone who has it will need the '
          'new one.',
      confirmLabel: 'Reset',
    );
    if (!ok || !mounted) return;
    await _run(() async {
      final invite = await widget.api.set(widget.groupId, reset: true);
      if (mounted) setState(() => _invite = invite);
    });
  }

  Future<void> _turnOff() async {
    final ok = await confirmAction(
      context,
      title: 'Turn off the link?',
      message:
          'It stops working, and anyone waiting to be let in is dropped. You can '
          'make a new one later.',
      confirmLabel: 'Turn off',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await _run(() async {
      await widget.api.turnOff(widget.groupId);
      if (mounted) {
        setState(() {
          _invite = const GroupInvite();
          _requests = const [];
        });
      }
    });
  }

  Future<void> _decide(JoinRequest request, {required bool approve}) => _run(
    () async {
      await widget.api.decide(widget.groupId, request.userId, approve: approve);
      if (mounted) {
        setState(
          () => _requests = _requests
              .where((r) => r.userId != request.userId)
              .toList(),
        );
      }
    },
  );

  String _link(GroupInvite invite) =>
      InviteLinks.linkFor(invite.code!).toString();

  @override
  Widget build(BuildContext context) {
    final invite = _invite;
    if (invite == null) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel('Invite link'),
        Section(
          children: [
            if (!invite.enabled)
              ElephantTile(
                icon: Icons.link_rounded,
                title: 'Create invite link',
                subtitle: 'Let people join by opening a link',
                onTap: _busy ? null : _create,
              )
            else ...[
              ElephantTile(
                icon: Icons.link_rounded,
                title: _link(invite),
                subtitle: 'Tap to copy',
                showChevron: false,
                trailing: const Icon(Icons.copy_rounded, size: 18),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: _link(invite)));
                  showSnack(context, 'Link copied');
                },
              ),
              ElephantTile(
                icon: Icons.ios_share_rounded,
                title: 'Share link',
                onTap: () =>
                    widget.share('Join my group on Elephant: ${_link(invite)}'),
              ),
              ElephantTile(
                icon: Icons.how_to_reg_outlined,
                title: 'Admins approve new members',
                subtitle: invite.requireApproval
                    ? 'People who open the link ask to join.'
                    : 'Anyone with the link joins at once.',
                showChevron: false,
                trailing: Switch(
                  value: invite.requireApproval,
                  onChanged: _busy ? null : _setApproval,
                ),
              ),
              ElephantTile(
                icon: Icons.refresh_rounded,
                title: 'Reset link',
                subtitle: 'The old link stops working',
                onTap: _busy ? null : _reset,
              ),
              ElephantTile(
                icon: Icons.link_off_rounded,
                title: 'Turn off link',
                destructive: true,
                showChevron: false,
                onTap: _busy ? null : _turnOff,
              ),
            ],
          ],
        ),
        if (_requests.isNotEmpty) ...[
          SectionLabel('Waiting to join (${_requests.length})'),
          Section(
            children: [
              for (final r in _requests)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Insets.lg,
                    vertical: Insets.sm,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(r.title, style: context.text.bodyLarge),
                            Text(
                              '@${r.username}',
                              style: context.text.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Turn ${r.title} down',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: _busy
                            ? null
                            : () => _decide(r, approve: false),
                      ),
                      IconButton(
                        tooltip: 'Let ${r.title} in',
                        icon: Icon(
                          Icons.check_rounded,
                          color: context.colors.primary,
                        ),
                        onPressed: _busy
                            ? null
                            : () => _decide(r, approve: true),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}
