import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:mobile/controllers/auth_state.dart';
import 'package:mobile/controllers/chat/active_chat_controller.dart';
import 'package:mobile/controllers/chat/group_details_controller.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/core/message_envelope.dart';
import 'package:mobile/models/message.dart';
import 'package:mobile/pages/chat/chat_details_page.dart';
import 'package:mobile/services/ws_service.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/chat_page_widgets.dart';
import 'package:mobile/widgets/ui/components.dart';
import 'package:mobile/widgets/ui/feedback.dart';
import 'package:mobile/widgets/ui/glass.dart';
import 'package:provider/provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

class ChatPage extends StatefulWidget {
  final String chatUserId;
  final String displayName;
  final String? username;
  final bool isGroup;

  const ChatPage({
    super.key,
    required this.chatUserId,
    required this.displayName,
    this.username,
    this.isGroup = false,
  });

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final ItemScrollController _scroll = ItemScrollController();
  final ItemPositionsListener _positions = ItemPositionsListener.create();
  final TextEditingController _composer = TextEditingController();
  final FocusNode _composerFocus = FocusNode();

  late final ActiveChatController _chat;
  late final AuthState _auth;

  late String _title = widget.displayName;
  Message? _replyingTo;
  Message? _editing;
  String? _highlightedId;
  Timer? _highlightTimer;
  bool _showScrollDown = false;
  double _composerHeight = 72;

  bool _searchMode = false;
  final TextEditingController _searchController = TextEditingController();
  List<Message> _searchResults = [];

  @override
  void initState() {
    super.initState();
    _chat = context.read<ActiveChatController>();
    _auth = context.read<AuthState>();
    _positions.itemPositions.addListener(_onScroll);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _chat.openChat(widget.chatUserId, isGroup: widget.isGroup);
      context.read<InboxController>().clearUnread(widget.chatUserId);
      if (widget.isGroup) {
        context.read<GroupDetailsController>().fetchGroupMembers(
          widget.chatUserId,
        );
      }
    });
  }

  @override
  void dispose() {
    _positions.itemPositions.removeListener(_onScroll);
    final closedChatId = widget.chatUserId;
    Future.microtask(() => _chat.closeChat(closedChatId));
    _highlightTimer?.cancel();
    _composer.dispose();
    _composerFocus.dispose();
    _searchController.dispose();
    super.dispose();
  }

  // --- Scrolling ---

  void _onScroll() {
    final positions = _positions.itemPositions.value;
    if (positions.isEmpty) return;

    final minIndex = positions
        .map((p) => p.index)
        .reduce((a, b) => a < b ? a : b);
    final maxIndex = positions
        .map((p) => p.index)
        .reduce((a, b) => a > b ? a : b);

    final scrolledUp = minIndex > 2;
    if (scrolledUp != _showScrollDown) {
      setState(() => _showScrollDown = scrolledUp);
    }

    final itemCount = _chat.activeChat.length + 2;
    if (maxIndex >= itemCount - 3) _chat.loadMoreMessages();
  }

  void _scrollToBottom() {
    if (_scroll.isAttached) {
      _scroll.scrollTo(
        index: 0,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _jumpToMessage(String messageId) {
    final messages = _chat.activeChat;
    final index = messages.indexWhere((m) => m.id == messageId);
    if (index == -1 || !_scroll.isAttached) {
      showSnack(context, 'That message is further back than what\'s loaded.');
      return;
    }

    _scroll.scrollTo(
      index: messages.length - index,
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeInOutCubic,
      alignment: 0.35,
    );
    setState(() => _highlightedId = messageId);
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _highlightedId = null);
    });
  }

  // --- Names ---

  bool _isMine(Message m) => m.isFrom(_auth.currentUser?.id);

  String _nameOf(String senderId) {
    final id = senderId.trim().toLowerCase();
    if (id == 'me' || id == _auth.currentUser?.id.toLowerCase()) return 'You';
    if (!widget.isGroup) return _title;
    return context.read<GroupDetailsController>().nameFor(id);
  }

  // --- Sending, replying, editing ---

  Future<void> _send(String text) async {
    final inbox = context.read<InboxController>();

    if (_editing != null) {
      final error = await _chat.editMessage(_editing!, text);
      if (!mounted) return;
      if (error != null) {
        showSnack(context, error, isError: true);
        return;
      }
      setState(() => _editing = null);
      _composer.clear();
      return;
    }

    final reply = _replyingTo;
    final error = await _chat.sendTextMessage(text, replyingTo: reply);
    if (!mounted) return;
    if (error != null) {
      showSnack(context, error, isError: true);
      return;
    }

    _composer.clear();
    setState(() => _replyingTo = null);
    inbox.updateLocalInboxState(
      widget.chatUserId,
      text,
      DateTime.now(),
      false,
      senderId: 'me',
      syncStatus: WebSocketService().isConnected ? 'synced' : 'pending',
    );
    _scrollToBottom();
  }

  void _startReply(Message message) {
    HapticFeedback.selectionClick();
    setState(() {
      _editing = null;
      _replyingTo = message;
    });
    _composerFocus.requestFocus();
  }

  void _startEdit(Message message) {
    setState(() {
      _replyingTo = null;
      _editing = message;
    });
    _composer.text = message.content;
    _composer.selection = TextSelection.collapsed(
      offset: _composer.text.length,
    );
    _composerFocus.requestFocus();
  }

  void _cancelBanner() {
    if (_editing != null) _composer.clear();
    setState(() {
      _editing = null;
      _replyingTo = null;
    });
  }

  Future<void> _showMessageActions(Message message) async {
    HapticFeedback.mediumImpact();
    final isLocked = message.content.startsWith(MessageEnvelope.lockedPrefix);
    final canEdit = !isLocked && message.canEdit(_auth.currentUser?.id);

    final action = await showActionSheet<String>(
      context,
      header: Padding(
        padding: const EdgeInsets.fromLTRB(Insets.xl, 0, Insets.xl, Insets.sm),
        child: Text(
          '${_nameOf(message.senderId)} · ${DateFormat.MMMd().add_jm().format(message.createdAt)}'
          '${message.isEdited ? ' · edited' : ''}',
          style: context.text.bodySmall?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
      ),
      actions: [
        const SheetAction(
          icon: Icons.reply_rounded,
          label: 'Reply',
          value: 'reply',
        ),
        if (!isLocked)
          const SheetAction(
            icon: Icons.copy_rounded,
            label: 'Copy text',
            value: 'copy',
          ),
        if (canEdit)
          const SheetAction(
            icon: Icons.edit_outlined,
            label: 'Edit',
            value: 'edit',
          ),
      ],
    );
    if (!mounted || action == null) return;

    switch (action) {
      case 'reply':
        _startReply(message);
        break;
      case 'copy':
        await Clipboard.setData(ClipboardData(text: message.content));
        if (mounted) showSnack(context, 'Copied');
        break;
      case 'edit':
        _startEdit(message);
        break;
    }
  }

  // --- Details & search ---

  Future<void> _openDetails() async {
    FocusScope.of(context).unfocus();
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatDetailsPage(
          chatId: widget.chatUserId,
          chatName: _title,
          username: widget.username,
          isGroup: widget.isGroup,
        ),
      ),
    );
    if (!mounted) return;

    // Opening a member's chat from group info replaces the active chat.
    if (_chat.currentChatUserId != widget.chatUserId &&
        result != ChatDetailsResult.left) {
      _chat.openChat(widget.chatUserId, isGroup: widget.isGroup);
    }

    if (result == ChatDetailsResult.search) {
      setState(() => _searchMode = true);
    } else if (result == ChatDetailsResult.left) {
      Navigator.pop(context);
    } else if (result is String) {
      setState(() => _title = result);
    }
  }

  Future<void> _runSearch(String query) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) {
      setState(() => _searchResults = []);
      return;
    }
    final messages = await _chat.getLocalMessagesForChat(widget.chatUserId);
    if (!mounted) return;
    setState(() {
      _searchResults = messages
          .where((m) => m.content.toLowerCase().contains(q))
          .toList()
          .reversed
          .toList();
    });
  }

  void _closeSearch() {
    setState(() {
      _searchMode = false;
      _searchController.clear();
      _searchResults = [];
    });
  }

  // --- Build ---

  String _subtitle(ActiveChatController chat, GroupDetailsController group) {
    if (chat.isPeerTyping) {
      return widget.isGroup ? 'someone is typing…' : 'typing…';
    }
    if (widget.isGroup) {
      final count = group.currentGroupMembers.length;
      return count > 0 ? '$count members · tap for info' : 'Tap for group info';
    }
    if (chat.isPeerOnline) return 'online';
    return widget.username != null
        ? '@${widget.username}'
        : 'Tap for contact info';
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ActiveChatController>();
    final group = context.watch<GroupDetailsController>();
    final messages = chat.currentChatUserId == widget.chatUserId
        ? chat.activeChat
        : const <Message>[];
    final topInset = MediaQuery.paddingOf(context).top + kToolbarHeight + 6;

    return PopScope(
      canPop: !_searchMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _searchMode) _closeSearch();
      },
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: _searchMode
            ? GlassAppBar(
                    leading: IconButton(
                      icon: const Icon(Icons.arrow_back_rounded),
                      onPressed: _closeSearch,
                    ),
                    titleSpacing: 0,
                    title: Padding(
                      padding: const EdgeInsets.only(right: Insets.lg),
                      child: GlassSearchField(
                        controller: _searchController,
                        hint: 'Search this chat',
                        autofocus: true,
                        onChanged: _runSearch,
                      ),
                    ),
                  )
                  as PreferredSizeWidget
            : ChatHeader(
                name: _title,
                seed: widget.chatUserId,
                isGroup: widget.isGroup,
                isOnline: widget.isGroup ? null : chat.isPeerOnline,
                subtitle: _subtitle(chat, group),
                highlightSubtitle:
                    chat.isPeerTyping || (!widget.isGroup && chat.isPeerOnline),
                onTitleTap: _openDetails,
                actions: [
                  IconButton(
                    tooltip: 'Search',
                    icon: const Icon(Icons.search_rounded),
                    onPressed: () => setState(() => _searchMode = true),
                  ),
                  const SizedBox(width: Insets.xs),
                ],
              ),
        body: AmbientBackground(
          intensity: 0.4,
          child: Stack(
            children: [
              Positioned.fill(
                child: _buildMessageList(chat, messages, topInset),
              ),
              if (_searchMode)
                Positioned.fill(top: topInset, child: _buildSearchResults()),
              if (!_searchMode)
                Positioned(
                  right: Insets.lg,
                  bottom: _composerHeight + Insets.md,
                  child: AnimatedScale(
                    scale: _showScrollDown ? 1 : 0,
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutBack,
                    child: GlassSurface(
                      strong: true,
                      borderRadius: BorderRadius.circular(99),
                      child: IconButton(
                        icon: const Icon(Icons.keyboard_arrow_down_rounded),
                        onPressed: _scrollToBottom,
                      ),
                    ),
                  ),
                ),
              if (!_searchMode)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _MeasureSize(
                    onChange: (size) {
                      if (size.height != _composerHeight) {
                        setState(() => _composerHeight = size.height);
                      }
                    },
                    child: ChatComposer(
                      controller: _composer,
                      focusNode: _composerFocus,
                      onSend: _send,
                      byteLimit: chat.messageByteLimit,
                      isEditing: _editing != null,
                      onTypingChanged: chat.sendTypingNotification,
                      banner: _editing != null
                          ? ComposerBanner(
                              icon: Icons.edit_outlined,
                              title: 'Editing message',
                              body: _editing!.content,
                              onClose: _cancelBanner,
                            )
                          : _replyingTo != null
                          ? ComposerBanner(
                              icon: Icons.reply_rounded,
                              title:
                                  'Replying to ${_nameOf(_replyingTo!.senderId)}',
                              body: _replyingTo!.content,
                              onClose: _cancelBanner,
                            )
                          : null,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMessageList(
    ActiveChatController chat,
    List<Message> messages,
    double topInset,
  ) {
    if (messages.isEmpty) {
      return Padding(
        padding: EdgeInsets.only(top: topInset, bottom: _composerHeight),
        child: chat.isChatHistoryLoading
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                child: Column(
                  children: [
                    EncryptionNotice(isGroup: widget.isGroup),
                    const SizedBox(height: 60),
                    EmptyState(
                      icon: widget.isGroup
                          ? Icons.groups_rounded
                          : Icons.waving_hand_rounded,
                      title: widget.isGroup
                          ? 'Start the conversation'
                          : 'Say hello',
                      message: widget.isGroup
                          ? 'Be the first to post in ${widget.displayName}.'
                          : 'Send ${widget.displayName} your first message.',
                    ),
                  ],
                ),
              ),
      );
    }

    // Reversed list: index 0 is the typing slot at the bottom, then newest →
    // oldest, then the header (loading more / encryption notice) at the top.
    return ScrollablePositionedList.builder(
      itemScrollController: _scroll,
      itemPositionsListener: _positions,
      reverse: true,
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: EdgeInsets.only(
        top: topInset + Insets.sm,
        bottom: _composerHeight + Insets.sm,
        left: Insets.md,
        right: Insets.md,
      ),
      itemCount: messages.length + 2,
      itemBuilder: (context, index) {
        if (index == 0) {
          return AnimatedSize(
            duration: const Duration(milliseconds: 200),
            child: chat.isPeerTyping
                ? const TypingIndicator()
                : const SizedBox(height: 0, width: double.infinity),
          );
        }
        if (index == messages.length + 1) {
          if (chat.isLoadingMore) {
            return const Padding(
              padding: EdgeInsets.all(Insets.lg),
              child: Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          return chat.hasMoreMessages
              ? const SizedBox(height: 40)
              : EncryptionNotice(isGroup: widget.isGroup);
        }

        final i = messages.length - index;
        final msg = messages[i];
        final prev = i > 0 ? messages[i - 1] : null;
        final next = i < messages.length - 1 ? messages[i + 1] : null;
        final isMe = _isMine(msg);

        bool sameRun(Message? other) {
          if (other == null) return false;
          return _isMine(other) == isMe &&
              (isMe ||
                  other.senderId.toLowerCase() == msg.senderId.toLowerCase()) &&
              DaySeparator.label(other.createdAt) ==
                  DaySeparator.label(msg.createdAt) &&
              other.createdAt.difference(msg.createdAt).inMinutes.abs() < 4;
        }

        final newDay =
            prev == null ||
            DaySeparator.label(prev.createdAt) !=
                DaySeparator.label(msg.createdAt);
        final quote = msg.quotedMessage;

        return Column(
          key: ValueKey(msg.id),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (newDay) DaySeparator(date: msg.createdAt),
            _SwipeToReply(
              isMe: isMe,
              onReply: () => _startReply(msg),
              child: GestureDetector(
                onLongPress: () => _showMessageActions(msg),
                child: ChatBubble(
                  message: msg,
                  isMe: isMe,
                  isGroup: widget.isGroup,
                  isFirstInRun: newDay || !sameRun(prev),
                  isLastInRun: !sameRun(next),
                  senderName: widget.isGroup && !isMe
                      ? _nameOf(msg.senderId)
                      : null,
                  senderSeed: msg.senderId.toLowerCase(),
                  quotedAuthor: quote != null && quote.senderId.isNotEmpty
                      ? _nameOf(quote.senderId)
                      : null,
                  highlighted: msg.id == _highlightedId,
                  onQuoteTap: quote != null
                      ? () => _jumpToMessage(quote.id)
                      : null,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSearchResults() {
    if (_searchResults.isEmpty) {
      return EmptyState(
        icon: Icons.manage_search_rounded,
        title: _searchController.text.isEmpty
            ? 'Search this chat'
            : 'No messages found',
        message: _searchController.text.isEmpty
            ? 'Searches the messages stored on this device.'
            : 'Try a different word.',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: Insets.sm),
      itemCount: _searchResults.length,
      itemBuilder: (context, index) {
        final msg = _searchResults[index];
        return ListTile(
          title: Text(
            msg.content,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${_nameOf(msg.senderId)} · ${DateFormat.yMMMd().add_jm().format(msg.createdAt)}',
          ),
          onTap: () {
            FocusScope.of(context).unfocus();
            _closeSearch();
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => _jumpToMessage(msg.id),
            );
          },
        );
      },
    );
  }
}

/// Reports its child's size after layout (used to pad the list above the
/// composer, whose height changes with reply/edit banners).
class _MeasureSize extends SingleChildRenderObjectWidget {
  final ValueChanged<Size> onChange;

  const _MeasureSize({required this.onChange, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _MeasureSizeRender(onChange);

  @override
  void updateRenderObject(
    BuildContext context,
    _MeasureSizeRender renderObject,
  ) {
    renderObject.onChange = onChange;
  }
}

class _MeasureSizeRender extends RenderProxyBox {
  ValueChanged<Size> onChange;
  Size? _last;

  _MeasureSizeRender(this.onChange);

  @override
  void performLayout() {
    super.performLayout();
    if (_last != size) {
      _last = size;
      WidgetsBinding.instance.addPostFrameCallback((_) => onChange(size));
    }
  }
}

/// Drag a bubble sideways to reply.
class _SwipeToReply extends StatefulWidget {
  final Widget child;
  final VoidCallback onReply;
  final bool isMe;

  const _SwipeToReply({
    required this.child,
    required this.onReply,
    required this.isMe,
  });

  @override
  State<_SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<_SwipeToReply>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..addListener(() => setState(() => _offset = _animation.value));
  late Animation<double> _animation = const AlwaysStoppedAnimation(0);
  double _offset = 0;
  bool _armed = false;
  static const double _threshold = 56;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _update(DragUpdateDetails details) {
    setState(() {
      _offset += details.primaryDelta ?? 0;
      _offset = widget.isMe
          ? _offset.clamp(-_threshold * 1.3, 0)
          : _offset.clamp(0, _threshold * 1.3);
      final armed = _offset.abs() >= _threshold;
      if (armed && !_armed) HapticFeedback.lightImpact();
      _armed = armed;
    });
  }

  void _end(DragEndDetails _) {
    if (_armed) widget.onReply();
    _armed = false;
    _animation = Tween<double>(
      begin: _offset,
      end: 0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _controller.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final progress = (_offset.abs() / _threshold).clamp(0.0, 1.0);
    return GestureDetector(
      onHorizontalDragUpdate: _update,
      onHorizontalDragEnd: _end,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(
            left: widget.isMe ? null : 8,
            right: widget.isMe ? 8 : null,
            child: Opacity(
              opacity: progress,
              child: Transform.scale(
                scale: 0.6 + 0.4 * progress,
                child: Icon(Icons.reply_rounded, color: context.colors.primary),
              ),
            ),
          ),
          Transform.translate(offset: Offset(_offset, 0), child: widget.child),
        ],
      ),
    );
  }
}
