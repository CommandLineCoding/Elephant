import 'package:flutter/material.dart';
import 'package:mobile/pages/chat/chat_page.dart';
import 'package:mobile/services/api_services.dart';
import 'package:mobile/services/group_invites.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/ui/avatar.dart';
import 'package:mobile/widgets/ui/components.dart';
import 'package:mobile/widgets/ui/surfaces.dart';

/// What opening a group invite link shows: the group's name and how many people
/// are in it, with Join (or Request to join, if an admin lets people in). It
/// shows no one's name before you join.
class JoinGroupPage extends StatefulWidget {
  final String code;
  final GroupInvitesApi api;

  /// Opens the group's chat. Replaced in tests.
  final void Function(BuildContext context, InvitePreview group, String groupId)
  openGroup;

  const JoinGroupPage({
    super.key,
    required this.code,
    this.api = const ServerGroupInvitesApi(),
    this.openGroup = _openChat,
  });

  static void _openChat(
    BuildContext context,
    InvitePreview preview,
    String groupId,
  ) {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => ChatPage(
          chatUserId: groupId.isEmpty ? preview.groupId : groupId,
          displayName: preview.name,
          isGroup: true,
        ),
      ),
    );
  }

  @override
  State<JoinGroupPage> createState() => _JoinGroupPageState();
}

class _JoinGroupPageState extends State<JoinGroupPage> {
  InvitePreview? _preview;
  String? _error;
  bool _busy = false;
  bool _requested = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final p = await widget.api.preview(widget.code);
      if (mounted) setState(() => _preview = p);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = ApiService.errorMessage(
            e,
            fallback: 'Couldn\'t open this invite link.',
          );
        });
      }
    }
  }

  Future<void> _join() async {
    final preview = _preview;
    if (preview == null) return;
    setState(() => _busy = true);
    try {
      final result = await widget.api.join(widget.code);
      if (!mounted) return;
      if (result.outcome == JoinOutcome.requested) {
        setState(() {
          _busy = false;
          _requested = true;
        });
        return;
      }
      _open(preview, result.groupId);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = ApiService.errorMessage(e, fallback: 'Couldn\'t join.');
      });
    }
  }

  void _open(InvitePreview preview, String groupId) =>
      widget.openGroup(context, preview, groupId);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const ElephantAppBar(title: Text('Group invitation')),
      body: ScreenBackground(child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    final preview = _preview;
    if (preview == null) {
      if (_error != null) {
        return EmptyState(
          icon: Icons.link_off_rounded,
          title: 'This link doesn\'t work',
          message: _error!,
          actionLabel: 'Try again',
          onAction: _load,
        );
      }
      return const Center(child: CircularProgressIndicator());
    }

    final waiting = _requested || preview.alreadyRequested;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Insets.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ElephantAvatar(
              name: preview.name,
              seed: preview.groupId,
              isGroup: true,
              size: 96,
            ),
            const SizedBox(height: Insets.lg),
            Text(
              preview.name,
              textAlign: TextAlign.center,
              style: context.text.headlineSmall,
            ),
            const SizedBox(height: Insets.xs),
            Text(
              '${preview.memberCount} ${preview.memberCount == 1 ? 'member' : 'members'}',
              style: context.text.bodyMedium?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Insets.xl),
            if (preview.alreadyMember)
              FilledButton(
                onPressed: () => _open(preview, preview.groupId),
                child: const Text('Open group'),
              )
            else if (waiting)
              Text(
                'Your request was sent. An admin will let you in.',
                textAlign: TextAlign.center,
                style: context.text.bodyMedium,
              )
            else ...[
              FilledButton(
                onPressed: _busy ? null : _join,
                child: Text(
                  preview.requireApproval ? 'Request to join' : 'Join group',
                ),
              ),
              if (preview.requireApproval)
                Padding(
                  padding: const EdgeInsets.only(top: Insets.md),
                  child: Text(
                    'An admin has to let you in.',
                    style: context.text.bodySmall?.copyWith(
                      color: context.colors.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: Insets.lg),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: context.text.bodyMedium?.copyWith(
                    color: context.colors.error,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
