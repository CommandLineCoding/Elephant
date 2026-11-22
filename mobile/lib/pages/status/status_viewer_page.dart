import 'package:flutter/material.dart';
import 'package:mobile/controllers/auth_state.dart';
import 'package:mobile/controllers/chat/active_chat_controller.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/core/status_content.dart';
import 'package:mobile/models/status.dart';
import 'package:mobile/services/nicknames.dart';
import 'package:mobile/services/statuses.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/ui/avatar.dart';
import 'package:mobile/widgets/ui/feedback.dart';
import 'package:provider/provider.dart';

/// Plays statuses full screen: each for a few seconds, then the next, then the
/// next person's. Tap the right to skip ahead and the left to go back, hold to
/// pause. A status of someone else's can be answered privately; one of the
/// person's own shows who has seen it.
/// How long a status stays on screen: longer for more words.
Duration statusDuration(StatusContent content) => Duration(
  milliseconds: (5000 + content.text.runes.length * 40).clamp(5000, 15000),
);

class StatusViewerPage extends StatefulWidget {
  /// Whose statuses to play, in order.
  final List<String> authors;

  /// Replaced in tests.
  final Statuses? statuses;

  const StatusViewerPage({super.key, required this.authors, this.statuses});

  @override
  State<StatusViewerPage> createState() => _StatusViewerPageState();
}

class _StatusViewerPageState extends State<StatusViewerPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _progress = AnimationController(vsync: this)
    ..addStatusListener((status) {
      if (status == AnimationStatus.completed) _next();
    });
  final _reply = TextEditingController();
  final _replyFocus = FocusNode();

  int _author = 0;
  int _index = 0;
  List<StatusPost> _posts = [];
  bool _held = false;

  Statuses get _statuses => widget.statuses ?? Statuses.instance;

  String get _myId =>
      context.read<AuthState>().currentUser?.id.toLowerCase() ?? '';

  @override
  void initState() {
    super.initState();
    _replyFocus.addListener(_onFocus);
    WidgetsBinding.instance.addPostFrameCallback((_) => _openAuthor(0));
  }

  @override
  void dispose() {
    _progress.dispose();
    _reply.dispose();
    _replyFocus.dispose();
    super.dispose();
  }

  StatusPost? get _current => _index < _posts.length ? _posts[_index] : null;

  bool get _isMine => _current?.authorId.toLowerCase() == _myId;

  void _openAuthor(int at) {
    if (!mounted) return;
    var i = at;
    while (i < widget.authors.length) {
      final posts = _statuses.postsBy(widget.authors[i]);
      if (posts.isNotEmpty) {
        final firstNew = posts.indexWhere((p) => !p.viewed);
        setState(() {
          _author = i;
          _posts = posts;
          _index = firstNew < 0 ? 0 : firstNew;
        });
        _play();
        return;
      }
      i++;
    }
    Navigator.maybePop(context);
  }

  void _play() {
    final post = _current;
    if (post == null || post.content == null) return;
    _progress
      ..duration = statusDuration(post.content!)
      ..forward(from: 0);
    _statuses.markViewed(post);
  }

  void _next() {
    if (!mounted) return;
    if (_index + 1 < _posts.length) {
      setState(() => _index++);
      _play();
    } else {
      _openAuthor(_author + 1);
    }
  }

  void _previous() {
    if (_index > 0) {
      setState(() => _index--);
    }
    _play();
  }

  void _pause() {
    if (_progress.isAnimating) _progress.stop();
  }

  void _resume() {
    if (_held || _replyFocus.hasFocus) return;
    if (_progress.status != AnimationStatus.completed) _progress.forward();
  }

  void _onFocus() => _replyFocus.hasFocus ? _pause() : _resume();

  String _nameOf(String userId) {
    final items = context.read<InboxController>().inbox;
    final item = items.where((i) => i.id.toLowerCase() == userId).firstOrNull;
    final title = item == null || item.title.isEmpty
        ? (item?.username ?? 'Contact')
        : item.title;
    return Nicknames.instance.nameFor(userId, title);
  }

  Future<void> _sendReply() async {
    final post = _current;
    final text = _reply.text.trim();
    if (post == null || post.content == null || text.isEmpty) return;
    final chat = context.read<ActiveChatController>();
    final (error, _) = await chat.sendTo(
      post.authorId,
      isGroup: false,
      text: statusReplyText(post.content!, text),
    );
    if (!mounted) return;
    if (error != null) {
      showSnack(context, error, isError: true);
      return;
    }
    _reply.clear();
    _replyFocus.unfocus();
    showSnack(context, 'Reply sent');
  }

  Future<void> _mute() async {
    final post = _current;
    if (post == null) return;
    await _statuses.mute(post.authorId);
    if (!mounted) return;
    showSnack(
      context,
      '${_nameOf(post.authorId.toLowerCase())}\'s status muted',
    );
    _openAuthor(_author + 1);
  }

  Future<void> _delete() async {
    final post = _current;
    if (post == null) return;
    _pause();
    final ok = await confirmAction(
      context,
      title: 'Delete this status?',
      message: 'It is removed for everyone who could see it.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!mounted) return;
    if (!ok) {
      _resume();
      return;
    }
    final error = await _statuses.delete(post);
    if (!mounted) return;
    if (error != null) {
      showSnack(context, error, isError: true);
      _resume();
      return;
    }
    final left = _statuses.postsBy(post.authorId);
    if (left.isEmpty) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _posts = left;
      _index = _index.clamp(0, left.length - 1);
    });
    _play();
  }

  Future<void> _showViewers() async {
    final post = _current;
    if (post == null) return;
    _pause();
    final viewers = _statuses.viewersOf(post.id);
    await showSheet<void>(
      context,
      title: 'Seen by ${viewers.length}',
      builder: (_) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.5,
        ),
        child: viewers.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(Insets.xl),
                child: Text(
                  'No one yet. People who have read receipts turned off '
                  'aren\'t shown.',
                  style: context.text.bodyMedium,
                ),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final v in viewers)
                    ListTile(
                      leading: ElephantAvatar(
                        name: _nameOf(v.userId),
                        seed: v.userId,
                        size: 40,
                      ),
                      title: Text(_nameOf(v.userId)),
                      subtitle: Text(statusAge(v.viewedAt, DateTime.now())),
                    ),
                ],
              ),
      ),
    );
    if (mounted) _resume();
  }

  @override
  Widget build(BuildContext context) {
    final post = _current;
    final content = post?.content;
    if (post == null || content == null) {
      return const Scaffold(backgroundColor: Colors.black);
    }
    final mine = _isMine;
    final author = post.authorId.toLowerCase();
    final name = mine ? 'Your status' : _nameOf(author);

    return Scaffold(
      backgroundColor: content.backgroundColor,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (d) {
                  final width = MediaQuery.sizeOf(context).width;
                  d.localPosition.dx < width / 3 ? _previous() : _next();
                },
                onLongPressStart: (_) {
                  _held = true;
                  _pause();
                },
                onLongPressEnd: (_) {
                  _held = false;
                  _resume();
                },
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Insets.xl,
                      vertical: 120,
                    ),
                    child: SingleChildScrollView(
                      child: Text(
                        content.text,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 28,
                          height: 1.3,
                          fontFamily: content.fontFamily,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: Insets.md,
              right: Insets.md,
              top: Insets.sm,
              child: Column(
                children: [
                  Row(
                    children: [
                      for (var i = 0; i < _posts.length; i++)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: i == _index
                                ? AnimatedBuilder(
                                    animation: _progress,
                                    builder: (_, _) => _Bar(_progress.value),
                                  )
                                : _Bar(i < _index ? 1 : 0),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: Insets.sm),
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'Close',
                        color: Colors.white,
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => Navigator.pop(context),
                      ),
                      ElephantAvatar(name: name, seed: author, size: 36),
                      const SizedBox(width: Insets.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.text.titleSmall?.copyWith(
                                color: Colors.white,
                              ),
                            ),
                            Text(
                              statusAge(post.createdAt, DateTime.now()),
                              style: context.text.bodySmall?.copyWith(
                                color: Colors.white70,
                              ),
                            ),
                          ],
                        ),
                      ),
                      PopupMenuButton<String>(
                        tooltip: 'More',
                        iconColor: Colors.white,
                        onOpened: _pause,
                        onCanceled: _resume,
                        onSelected: (v) {
                          if (v == 'mute') _mute();
                          if (v == 'delete') _delete();
                        },
                        itemBuilder: (_) => [
                          if (mine)
                            const PopupMenuItem(
                              value: 'delete',
                              child: Text('Delete'),
                            )
                          else
                            const PopupMenuItem(
                              value: 'mute',
                              child: Text('Mute status'),
                            ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Positioned(
              left: Insets.page,
              right: Insets.page,
              bottom: Insets.md,
              child: mine
                  ? Center(
                      child: TextButton.icon(
                        onPressed: _showViewers,
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white,
                        ),
                        icon: const Icon(Icons.visibility_outlined),
                        label: Text(
                          'Seen by ${_statuses.viewersOf(post.id).length}',
                        ),
                      ),
                    )
                  : TextField(
                      controller: _reply,
                      focusNode: _replyFocus,
                      textCapitalization: TextCapitalization.sentences,
                      style: const TextStyle(color: Colors.white),
                      cursorColor: Colors.white,
                      onSubmitted: (_) => _sendReply(),
                      decoration: InputDecoration(
                        hintText: 'Reply privately',
                        hintStyle: const TextStyle(color: Colors.white70),
                        filled: true,
                        fillColor: Colors.black26,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(99),
                          borderSide: BorderSide.none,
                        ),
                        suffixIcon: IconButton(
                          tooltip: 'Send reply',
                          color: Colors.white,
                          icon: const Icon(Icons.send_rounded),
                          onPressed: _sendReply,
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  final double value;

  const _Bar(this.value);

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(2),
    child: LinearProgressIndicator(
      value: value,
      minHeight: 3,
      color: Colors.white,
      backgroundColor: Colors.white30,
    ),
  );
}
