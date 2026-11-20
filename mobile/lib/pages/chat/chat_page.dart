import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:mobile/core/links.dart';
import 'package:mobile/controllers/auth_state.dart';
import 'package:mobile/controllers/chat/active_chat_controller.dart';
import 'package:mobile/controllers/chat/group_details_controller.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/core/message_envelope.dart';
import 'package:mobile/models/message.dart';
import 'package:mobile/services/blocked_users.dart';
import 'package:mobile/pages/chat/forward_page.dart';
import 'package:mobile/pages/chat/block_user.dart';
import 'package:mobile/controllers/call/call_controller.dart';
import 'package:mobile/pages/call/call_page.dart';
import 'package:mobile/services/calls/call_log.dart';
import 'package:mobile/widgets/poll_widgets.dart';
import 'package:mobile/widgets/reaction_widgets.dart';
import 'package:mobile/core/link_preview.dart';
import 'package:mobile/core/poll.dart';
import 'package:mobile/widgets/link_preview_widgets.dart';
import 'package:mobile/core/shared_contact.dart';
import 'package:mobile/core/shared_location.dart';
import 'package:mobile/services/location_service.dart';
import 'package:mobile/widgets/location_widgets.dart';
import 'package:mobile/pages/chat/contact_picker_page.dart';
import 'package:mobile/widgets/contact_widgets.dart';
import 'package:mobile/pages/chat/create_poll_page.dart';
import 'package:mobile/widgets/call_log_row.dart';
import 'package:mobile/pages/chat/delete_chat.dart';
import 'package:mobile/pages/chat/chat_details_page.dart';
import 'package:mobile/services/ws_service.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/chat_page_widgets.dart';
import 'package:mobile/widgets/ui/components.dart';
import 'package:mobile/widgets/ui/feedback.dart';
import 'package:mobile/widgets/ui/surfaces.dart';
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
    _composer.addListener(_onComposerChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _chat.openChat(widget.chatUserId, isGroup: widget.isGroup);
      if (!widget.isGroup) CallLog.instance.load(widget.chatUserId);
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
    _composer.removeListener(_onComposerChanged);
    _previewTimer?.cancel();
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

    final itemCount = _shown.length + 2;
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
    final messages = _shown;
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
    // The preview only goes if its link is still in the text.
    final preview = _preview != null && linksIn(text).contains(_preview!.url)
        ? _preview
        : null;
    final error = await _chat.sendTextMessage(
      text,
      replyingTo: reply,
      preview: preview,
    );
    if (!mounted) return;
    if (error != null) {
      showSnack(context, error, isError: true);
      return;
    }

    _composer.clear();
    setState(() => _replyingTo = null);
    _noteSent(text);
  }

  /// Shows [preview] as the chat's last message in the chat list, and scrolls
  /// to the message just sent.
  void _noteSent(String preview) {
    context.read<InboxController>().updateLocalInboxState(
      widget.chatUserId,
      preview,
      DateTime.now(),
      false,
      senderId: 'me',
      syncStatus: WebSocketService().isConnected ? 'synced' : 'pending',
    );
    _scrollToBottom();
  }

  // --- Attachments and polls ---

  Future<void> _showAttach() async {
    final choice = await showActionSheet<String>(
      context,
      actions: const [
        SheetAction(icon: Icons.poll_outlined, label: 'Poll', value: 'poll'),
        SheetAction(
          icon: Icons.person_outline_rounded,
          label: 'Contact',
          value: 'contact',
        ),
        SheetAction(
          icon: Icons.place_outlined,
          label: 'Location',
          value: 'location',
        ),
      ],
    );
    if (!mounted || choice == null) return;
    if (choice == 'poll') await _createPoll();
    if (choice == 'contact') await _shareContact();
    if (choice == 'location') await _shareLocation();
  }

  Future<void> _shareLocation() async {
    final ok = await confirmAction(
      context,
      title: 'Share your location?',
      message:
          'This sends where you are right now to ${widget.isGroup ? 'the group' : _title}. '
          'It is not updated as you move.',
      confirmLabel: 'Share',
    );
    if (!ok || !mounted) return;

    showSnack(context, 'Finding your location…');
    final found = await LocationService().current();
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();

    final here = found.location;
    if (here == null) {
      showSnack(context, switch (found.problem) {
        LocationProblem.denied =>
          'Allow location access for Elephant in Settings to share where you are.',
        LocationProblem.disabled =>
          'Turn on location on your phone to share where you are.',
        _ => "Couldn't find your location. Try again outside or near a window.",
      }, isError: true);
      return;
    }

    final error = await _chat.sendLocation(
      SharedLocation(here.lat, here.lon, accuracy: here.accuracy),
    );
    if (!mounted) return;
    if (error != null) {
      showSnack(context, error, isError: true);
      return;
    }
    _noteSent('📍 Location');
  }

  Future<void> _shareContact() async {
    final contact = await Navigator.push<SharedContact>(
      context,
      MaterialPageRoute(
        builder: (_) => ContactPickerPage(
          exceptId: widget.isGroup ? null : widget.chatUserId,
        ),
      ),
    );
    if (contact == null || !mounted) return;
    final error = await _chat.sendContact(contact);
    if (!mounted) return;
    if (error != null) {
      showSnack(context, error, isError: true);
      return;
    }
    _noteSent('👤 Contact: ${contact.name}');
  }

  /// A shared contact as a card, or null if [message] isn't one.
  Widget Function(Color)? _cardFor(Message message) {
    final contact = SharedContact.fromPayload(message.payload);
    if (contact != null) {
      final me = _auth.currentUser?.id.toLowerCase();
      final isMe = contact.id.toLowerCase() == me;
      final isThisChat =
          !widget.isGroup &&
          contact.id.toLowerCase() == widget.chatUserId.toLowerCase();
      return (textColor) => ContactCard(
        contact: contact,
        textColor: textColor,
        onMessage: isMe || isThisChat ? null : () => _openChatWith(contact),
      );
    }
    final location = SharedLocation.fromPayload(message.payload);
    if (location != null) {
      return (textColor) => LocationCard(
        location: location,
        textColor: textColor,
        onOpen: () async {
          if (!await openInMaps(location) && mounted) {
            showSnack(context, "Couldn't open a maps app", isError: true);
          }
        },
      );
    }
    return null;
  }

  /// Opens a chat with a shared contact on top of this one, and gets this one
  /// back when it's closed (there is one open chat at a time).
  Future<void> _openChatWith(SharedContact contact) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatPage(
          chatUserId: contact.id,
          displayName: contact.name,
          username: contact.username,
        ),
      ),
    );
    if (!mounted) return;
    if (_chat.currentChatUserId != widget.chatUserId) {
      _chat.openChat(widget.chatUserId, isGroup: widget.isGroup);
    }
  }

  Future<void> _createPoll() async {
    final poll = await Navigator.push<PollData>(
      context,
      MaterialPageRoute(builder: (_) => const CreatePollPage()),
    );
    if (poll == null || !mounted) return;
    final error = await _chat.sendPoll(poll);
    if (!mounted) return;
    if (error != null) {
      showSnack(context, error, isError: true);
      return;
    }
    _noteSent('📊 Poll: ${poll.question}');
  }

  PollView? _pollViewFor(Message message, ActiveChatController chat) {
    final poll = PollData.fromPayload(message.payload);
    if (poll == null) return null;
    final tally = chat.meta.tallyOf(message.id, poll);
    final canVote = !_isBlocked && !message.isPending;
    return PollView(
      poll: poll,
      tally: tally,
      mine: tally.picksOf('me'),
      onToggle: canVote
          ? (option) => _toggleVote(message, poll, tally, option)
          : null,
      onShowVotes: () =>
          showPollVotes(context, poll: poll, tally: tally, nameOf: _nameOf),
    );
  }

  Future<void> _toggleVote(
    Message message,
    PollData poll,
    PollTally tally,
    int option,
  ) async {
    final mine = tally.picksOf('me');
    final next = poll.multi
        ? ({...mine}..toggle(option))
        : (mine.contains(option) ? <int>{} : {option});
    final error = await _chat.vote(message, next);
    if (error != null && mounted) showSnack(context, error, isError: true);
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
    _composer.text = message.text;
    _composer.selection = TextSelection.collapsed(
      offset: _composer.text.length,
    );
    _composerFocus.requestFocus();
  }

  // --- Link previews ---

  LinkPreview? _preview;

  /// The link [_preview] was (or is being) made for, so one isn't looked up
  /// twice, and one that was dismissed doesn't come back.
  String? _previewLink;
  Timer? _previewTimer;
  int _previewRequest = 0;

  /// The first link in [text] that a preview may be fetched for.
  String? _previewableLink(String text) {
    for (final link in linksIn(text)) {
      final uri = Uri.tryParse(link);
      if (uri != null && isFetchableUri(uri)) return link;
    }
    return null;
  }

  void _onComposerChanged() {
    _previewTimer?.cancel();
    final link = _editing != null ? null : _previewableLink(_composer.text);
    if (link == null) {
      _clearPreview();
      return;
    }
    if (link == _previewLink) return;
    // Wait for a pause in typing, so half a link isn't looked up.
    _previewTimer = Timer(
      const Duration(milliseconds: 700),
      () => _fetchPreview(link),
    );
  }

  void _clearPreview() {
    _previewRequest++;
    if (_preview != null || _previewLink != null) {
      setState(() {
        _preview = null;
        _previewLink = null;
      });
    }
  }

  Future<void> _fetchPreview(String link) async {
    final request = ++_previewRequest;
    if (!await LinkPreviewPrefs.isEnabled()) return;
    if (!mounted || request != _previewRequest) return;
    final preview = await LinkPreviewFetcher.shared.fetch(link);
    if (!mounted || request != _previewRequest) return;
    setState(() {
      _previewLink = link;
      _preview = preview;
    });
  }

  /// Everything above the message box: what's being edited or replied to,
  /// and the preview of a link being written.
  Widget? _composerBanner() {
    final Widget? above = _editing != null
        ? ComposerBanner(
            icon: Icons.edit_outlined,
            title: 'Editing message',
            body: _editing!.text,
            onClose: _cancelBanner,
          )
        : _replyingTo != null
        ? ComposerBanner(
            icon: Icons.reply_rounded,
            title: 'Replying to ${_nameOf(_replyingTo!.senderId)}',
            body: _replyingTo!.text,
            onClose: _cancelBanner,
          )
        : null;
    final preview = _preview;
    if (preview == null) return above;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ?above,
        LinkPreviewBar(
          preview: preview,
          onClose: () => setState(() => _preview = null),
        ),
      ],
    );
  }

  /// A link preview that came with [message], drawn under its text.
  Widget Function(Color)? _previewFor(Message message) {
    final preview = LinkPreview.fromPayload(
      message.payload,
      messageText: message.text,
    );
    if (preview == null) return null;
    return (textColor) => LinkPreviewCard(
      preview: preview,
      textColor: textColor,
      onOpen: () => confirmAndOpenLink(context, preview.url),
    );
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
    final links = isLocked ? const <String>[] : linksIn(message.text);

    // Nobody to react to once you've blocked them, or if it can't be read.
    final canReact = !isLocked && !_isBlocked && !message.isPending;
    final canPin = canReact && _chat.canPin;
    final isPinned = _chat.meta.isPinned(message.id);
    final myReaction = _chat.meta.myReactionTo(message.id);

    final action = await showActionSheet<String>(
      context,
      header: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Insets.xl,
              0,
              Insets.xl,
              Insets.sm,
            ),
            child: Text(
              '${_nameOf(message.senderId)} · ${DateFormat.MMMd().add_jm().format(message.createdAt)}'
              '${message.isEdited ? ' · edited' : ''}',
              style: context.text.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
          ),
          if (canReact) ReactionPicker(mine: myReaction),
        ],
      ),
      actions: [
        const SheetAction(
          icon: Icons.reply_rounded,
          label: 'Reply',
          value: 'reply',
        ),
        if (canPin)
          SheetAction(
            icon: isPinned ? Icons.push_pin : Icons.push_pin_outlined,
            label: isPinned ? 'Unpin' : 'Pin',
            value: isPinned ? 'unpin' : 'pin',
          ),
        if (!isLocked)
          const SheetAction(
            icon: Icons.copy_rounded,
            label: 'Copy text',
            value: 'copy',
          ),
        if (!isLocked)
          const SheetAction(
            icon: Icons.shortcut_rounded,
            label: 'Forward',
            value: 'forward',
          ),
        if (links.isNotEmpty)
          SheetAction(
            icon: Icons.link_rounded,
            label: links.length == 1 ? 'Copy link' : 'Copy links',
            value: 'copy-links',
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

    if (action.startsWith(reactPrefix)) {
      await _react(message, action.substring(reactPrefix.length));
      return;
    }

    switch (action) {
      case reactMorePrefix:
        final emoji = await showEmojiGrid(context, mine: myReaction);
        if (emoji != null && mounted) await _react(message, emoji);
        break;
      case 'pin':
        await _setPinned(message, true);
        break;
      case 'unpin':
        await _setPinned(message, false);
        break;
      case 'reply':
        _startReply(message);
        break;
      case 'forward':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ForwardPage(text: message.content)),
        );
        break;
      case 'copy':
        await Clipboard.setData(ClipboardData(text: message.text));
        if (mounted) showSnack(context, 'Copied');
        break;
      case 'copy-links':
        await Clipboard.setData(ClipboardData(text: links.join('\n')));
        if (mounted) showSnack(context, 'Copied');
        break;
      case 'edit':
        _startEdit(message);
        break;
    }
  }

  bool get _isBlocked =>
      !widget.isGroup && BlockedUsers.instance.isBlocked(widget.chatUserId);

  int _pinCursor = 0;

  /// The pinned messages that are on screen, newest pin first.
  List<Message> _pinnedMessages(
    ActiveChatController chat,
    List<Message> shown,
  ) {
    if (chat.meta.pinned.isEmpty) return const [];
    final byId = {for (final m in shown) m.id: m};
    return [
      for (final id in chat.meta.pinned.reversed)
        if (byId[id] != null) byId[id]!,
    ];
  }

  Future<void> _setPinned(Message message, bool pinned) async {
    final error = await _chat.setPinned(message, pinned);
    if (error != null && mounted) showSnack(context, error, isError: true);
  }

  Future<void> _react(Message message, String emoji) async {
    final error = await _chat.react(message, emoji);
    if (error != null && mounted) showSnack(context, error, isError: true);
  }

  void _showReactions(Message message) {
    final groups = _chat.meta.reactionsOn(message.id);
    if (groups.isEmpty) return;
    showReactionList(
      context,
      groups: groups,
      nameOf: _nameOf,
      onRemoveMine: () => _react(message, _chat.meta.myReactionTo(message.id)!),
    );
  }

  Future<void> _onMenu(String value) async {
    if (value == 'block') {
      await confirmAndBlock(
        context,
        BlockedUser(
          id: widget.chatUserId,
          username: widget.username ?? '',
          displayName: _title,
        ),
      );
    } else if (value == 'unblock') {
      await unblock(context, widget.chatUserId, _title);
    } else if (value == 'delete') {
      final deleted = await confirmAndDeleteChat(
        context,
        chatId: widget.chatUserId,
        title: _title,
        isGroup: widget.isGroup,
      );
      if (deleted && mounted) Navigator.pop(context);
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
          // Actions (reactions, votes, pins) aren't messages to find.
          .where((m) => !m.isAction && m.text.toLowerCase().contains(q))
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
    return ListenableBuilder(
      listenable: Listenable.merge([BlockedUsers.instance, CallLog.instance]),
      builder: (context, _) => _buildPage(context),
    );
  }

  /// What the list shows: the messages, with this chat's calls in between.
  List<Message> _shown = const [];
  final Map<String, CallLogEntry> _callRows = {};

  /// Adds the chat's calls to [messages] as placeholder rows (see
  /// [_isCallRow]). While older messages are still to load, calls from before
  /// the oldest loaded message wait for them, so they land in the right place.
  List<Message> _withCalls(List<Message> messages, bool hasMore) {
    _callRows.clear();
    if (widget.isGroup) return messages;
    final calls = CallLog.instance.entriesFor(widget.chatUserId);
    if (calls.isEmpty) return messages;

    final from = hasMore && messages.isNotEmpty
        ? messages.first.createdAt
        : null;
    final rows = <Message>[];
    for (final call in calls) {
      if (from != null && call.startedAt.isBefore(from)) continue;
      final id = 'call:${call.id}';
      _callRows[id] = call;
      rows.add(
        Message(
          id: id,
          senderId: call.outgoing ? 'me' : widget.chatUserId,
          receiverId: '',
          content: '',
          createdAt: call.startedAt,
          isRead: true,
          syncStatus: _callRowStatus,
        ),
      );
    }
    return [...messages, ...rows]
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  static const _callRowStatus = 'call';

  bool _isCallRow(Message? m) => m?.syncStatus == _callRowStatus;

  Future<void> _startCall() async {
    final calls = CallController.instance;
    // A second tap while the call screen opens mustn't open another.
    if (calls == null || !(ModalRoute.of(context)?.isCurrent ?? true)) return;
    if (calls.isActive) {
      Navigator.of(context).push(CallPage.route(calls));
      return;
    }
    Navigator.of(context).push(CallPage.route(calls));
    final error = await calls.call(widget.chatUserId, widget.displayName);
    if (error != null && mounted) showSnack(context, error, isError: true);
  }

  Widget _buildPage(BuildContext context) {
    final chat = context.watch<ActiveChatController>();
    final group = context.watch<GroupDetailsController>();
    final messages = _shown = _withCalls(
      chat.currentChatUserId == widget.chatUserId
          ? chat.visibleChat
          : const <Message>[],
      chat.hasMoreMessages,
    );
    final topInset = MediaQuery.paddingOf(context).top + kToolbarHeight + 6;
    // Only admins' pins count in a group, so the controller needs to know who
    // they are (it doesn't notify: this only changes what `meta` adds up).
    chat.updateGroupAdmins(
      widget.isGroup && group.currentGroupMembers.isNotEmpty
          ? {
              for (final m in group.currentGroupMembers)
                if (m.isAdmin) m.userId.trim().toLowerCase(),
            }
          : null,
    );
    final pins = _pinnedMessages(chat, messages);

    return PopScope(
      canPop: !_searchMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _searchMode) _closeSearch();
      },
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: _searchMode
            ? ElephantAppBar(
                    leading: IconButton(
                      tooltip: 'Close search',
                      icon: const Icon(Icons.arrow_back_rounded),
                      onPressed: _closeSearch,
                    ),
                    titleSpacing: 0,
                    title: Padding(
                      padding: const EdgeInsets.only(right: Insets.lg),
                      child: SearchField(
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
                  if (!widget.isGroup && !_isBlocked)
                    IconButton(
                      tooltip: 'Voice call',
                      icon: const Icon(Icons.call_outlined),
                      onPressed: _startCall,
                    ),
                  IconButton(
                    tooltip: 'Search',
                    icon: const Icon(Icons.search_rounded),
                    onPressed: () => setState(() => _searchMode = true),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'More',
                    icon: const Icon(Icons.more_vert_rounded),
                    onSelected: _onMenu,
                    itemBuilder: (_) => [
                      if (!widget.isGroup)
                        PopupMenuItem(
                          value: _isBlocked ? 'unblock' : 'block',
                          child: Text(_isBlocked ? 'Unblock' : 'Block'),
                        ),
                      PopupMenuItem(
                        value: 'delete',
                        child: Text(
                          widget.isGroup ? 'Clear chat' : 'Delete chat',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: Insets.xs),
                ],
              ),
        body: ScreenBackground(
          child: Stack(
            children: [
              Positioned.fill(
                child: _buildMessageList(chat, messages, topInset),
              ),
              if (_searchMode)
                Positioned.fill(top: topInset, child: _buildSearchResults()),
              // Slim bars under the header: with cached messages on screen, a
              // failed load is one rather than replacing the chat, and the
              // pinned messages are another.
              if (!_searchMode &&
                  ((chat.historyError != null && messages.isNotEmpty) ||
                      pins.isNotEmpty))
                Positioned(
                  top: topInset + Insets.sm,
                  left: Insets.md,
                  right: Insets.md,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (chat.historyError != null && messages.isNotEmpty)
                        _HistoryErrorBar(
                          message: chat.historyError!,
                          onRetry: chat.retryHistory,
                        ),
                      if (chat.historyError != null &&
                          messages.isNotEmpty &&
                          pins.isNotEmpty)
                        const SizedBox(height: Insets.sm),
                      if (pins.isNotEmpty)
                        _PinnedBar(
                          message: pins[_pinCursor % pins.length],
                          position: _pinCursor % pins.length,
                          total: pins.length,
                          onTap: () {
                            _jumpToMessage(pins[_pinCursor % pins.length].id);
                            setState(() => _pinCursor++);
                          },
                        ),
                    ],
                  ),
                ),
              if (!_searchMode)
                Positioned(
                  right: Insets.lg,
                  bottom: _composerHeight + Insets.md,
                  // While hidden it is scaled to nothing, so it must also be
                  // out of reach of taps and screen readers.
                  child: IgnorePointer(
                    ignoring: !_showScrollDown,
                    child: ExcludeSemantics(
                      excluding: !_showScrollDown,
                      child: AnimatedScale(
                        scale: _showScrollDown ? 1 : 0,
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutBack,
                        child: Panel(
                          borderRadius: BorderRadius.circular(99),
                          child: IconButton(
                            tooltip: 'Scroll to latest message',
                            icon: const Icon(Icons.keyboard_arrow_down_rounded),
                            onPressed: _scrollToBottom,
                          ),
                        ),
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
                    child: _isBlocked
                        ? BlockedBanner(
                            displayName: _title,
                            onUnblock: () =>
                                unblock(context, widget.chatUserId, _title),
                          )
                        : ChatComposer(
                            controller: _composer,
                            focusNode: _composerFocus,
                            onSend: _send,
                            onAttach: _showAttach,
                            byteLimit: chat.messageByteLimit,
                            isEditing: _editing != null,
                            onTypingChanged: chat.sendTypingNotification,
                            banner: _composerBanner(),
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
            : chat.historyError != null
            ? EmptyState(
                icon: Icons.cloud_off_rounded,
                title: chat.historyError!,
                message: 'Check your connection and try again.',
                actionLabel: 'Try again',
                onAction: chat.retryHistory,
              )
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

        if (_isCallRow(msg)) {
          final newDay =
              prev == null ||
              DaySeparator.label(prev.createdAt) !=
                  DaySeparator.label(msg.createdAt);
          return Column(
            key: ValueKey(msg.id),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (newDay) DaySeparator(date: msg.createdAt),
              CallLogRow(entry: _callRows[msg.id]!, onCallBack: _startCall),
            ],
          );
        }

        bool sameRun(Message? other) {
          if (other == null || _isCallRow(other)) return false;
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
                  reactions: chat.meta.reactionsOn(msg.id),
                  onReactionsTap: () => _showReactions(msg),
                  poll: _pollViewFor(msg, chat),
                  cardBuilder: _cardFor(msg),
                  previewBuilder: _previewFor(msg),
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
          title: Text(msg.text, maxLines: 2, overflow: TextOverflow.ellipsis),
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

/// The pinned message under the header. Tapping it jumps to the message, and
/// then to the next pinned one.
class _PinnedBar extends StatelessWidget {
  final Message message;
  final int position;
  final int total;
  final VoidCallback onTap;

  const _PinnedBar({
    required this.message,
    required this.position,
    required this.total,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final text = message.text.trim().isEmpty ? 'Message' : message.text.trim();
    return Semantics(
      button: true,
      label:
          'Pinned message${total > 1 ? ' ${position + 1} of $total' : ''}: '
          '$text. Go to message',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: Panel(
          borderRadius: BorderRadius.circular(Radii.md),
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
          child: Row(
            children: [
              Icon(
                Icons.push_pin_rounded,
                size: 18,
                color: context.colors.primary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      total > 1
                          ? 'Pinned message ${position + 1} of $total'
                          : 'Pinned message',
                      style: context.text.labelSmall?.copyWith(
                        color: context.colors.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      text.replaceAll('\n', ' '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.bodyMedium,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Couldn't load messages · Try again", shown over the top of a chat whose
/// cached messages are still visible.
class _HistoryErrorBar extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _HistoryErrorBar({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Panel(
      borderRadius: BorderRadius.circular(Radii.md),
      padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
      child: Row(
        children: [
          Icon(
            Icons.cloud_off_rounded,
            size: 18,
            color: context.colors.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: context.text.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(
              foregroundColor: context.colors.onSurface,
            ),
            child: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}

extension on Set<int> {
  /// Adds [value] if it isn't there, removes it if it is.
  void toggle(int value) {
    if (!remove(value)) add(value);
  }
}
