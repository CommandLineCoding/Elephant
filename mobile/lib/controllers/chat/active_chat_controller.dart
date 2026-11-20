import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart' show Response;
import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:mobile/core/constants.dart';
import 'package:mobile/controllers/chat/chat_meta.dart';
import 'package:mobile/core/link_preview.dart';
import 'package:mobile/core/message_envelope.dart';
import 'package:mobile/core/message_payload.dart';
import 'package:mobile/core/poll.dart';
import 'package:mobile/core/shared_contact.dart';
import 'package:mobile/core/shared_location.dart';
import 'package:mobile/services/signal_service.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../../models/message.dart';
import '../../services/api_services.dart';
import '../../services/ws_service.dart';
import '../../services/db_services.dart';

class ActiveChatController extends ChangeNotifier {
  final ApiService _api = ApiService();
  final WebSocketService _ws = WebSocketService();
  final Uuid _uuid = const Uuid();

  /// Resolves the signed-in user's ID (set from main.dart).
  String Function() currentUserIdProvider = () => '';
  String get _myId => currentUserIdProvider();

  bool isLoadingMore = false;
  bool hasMoreMessages = true;

  /// Set when loading the chat's history failed, either the latest page or
  /// an older one. Cached messages stay visible; [retryHistory] tries again.
  String? historyError;
  int _currentRequestId = 0;
  List<Message> _activeChat = [];
  List<Message>? _visibleChat;
  ChatMeta? _meta;
  String? currentChatUserId;
  bool isPeerTyping = false;
  bool isPeerOnline = false;
  bool isChatHistoryLoading = false;
  bool isCurrentChatGroup = false;
  int chatOpenCount = 0;

  /// Every message of the open chat, oldest first, including actions
  /// (reactions, votes, pins) that aren't shown as messages.
  List<Message> get activeChat => _activeChat;

  set activeChat(List<Message> messages) {
    _activeChat = messages;
    _visibleChat = null;
    _meta = null;
  }

  Set<String>? _groupAdmins;

  /// Tells the controller who the open group's admins are (lowercase user IDs),
  /// since only their pins count. Null while unknown.
  void updateGroupAdmins(Set<String>? admins) {
    if (setEquals(admins, _groupAdmins)) return;
    _groupAdmins = admins;
    _meta = null;
  }

  /// What the open chat's actions add up to (reactions, pins).
  ChatMeta get meta => _meta ??= ChatMeta.from(
    _activeChat,
    _myId,
    isGroup: isCurrentChatGroup,
    admins: _groupAdmins,
  );

  /// Whether we can pin or unpin in the open chat: anyone in a direct chat,
  /// admins in a group.
  bool get canPin =>
      !isCurrentChatGroup ||
      (_groupAdmins?.contains(_myId.trim().toLowerCase()) ?? false);

  /// What the message list shows: [activeChat] without the actions.
  List<Message> get visibleChat =>
      _visibleChat ??= _activeChat.where((m) => !m.isAction).toList();

  void refreshUI() => notifyListeners();

  /// Called after the signed-in user edits a message, so the inbox can show the
  /// new text (set from main.dart).
  Future<void> Function(String chatId, String messageId, String text)?
  onMessageEdited;

  /// Applies an edit someone else made, pushed over the WebSocket, to the open
  /// chat.
  void applyRemoteEdit(String messageId, String content, DateTime editedAt) {
    final updated = withEditApplied(activeChat, messageId, content, editedAt);
    if (identical(updated, activeChat)) return;
    activeChat = _withResolvedQuotes(updated);
    notifyListeners();
  }

  /// Sends the delete request. Tests replace it.
  Future<Response> Function(String messageId, {required bool forEveryone})
  messageDeleter = ApiService().deleteMessage;

  /// Called after a message is deleted, so the chat list can follow (set from
  /// main.dart).
  Future<void> Function(String chatId)? onMessageDeleted;

  /// Deletes [message] in the open chat. For [forEveryone] it has to be ours:
  /// it becomes "This message was deleted" for everyone. Otherwise it's only
  /// removed from our own view. Returns an error to show, or null.
  Future<String?> deleteMessage(
    Message message, {
    required bool forEveryone,
  }) async {
    final chatId = currentChatUserId;
    if (chatId == null) return null;
    if (forEveryone && !_isMine(message)) {
      return 'You can only delete your own messages for everyone.';
    }
    try {
      final res = await messageDeleter(message.id, forEveryone: forEveryone);
      if (forEveryone) {
        final at =
            Message.fromJson({
              'deleted_at': ApiService.dataMap(res.data)['deleted_at'],
            }).deletedAt ??
            DateTime.now();
        applyDeletion(message.id, at);
        await _remember(
          () => DatabaseHelper.instance.markMessageDeleted(message.id, at),
        );
      } else {
        activeChat = activeChat.where((m) => m.id != message.id).toList();
        notifyListeners();
        await _remember(
          () => DatabaseHelper.instance.deleteMessageById(message.id),
        );
      }
      await onMessageDeleted?.call(chatId);
      return null;
    } catch (e) {
      debugPrint("Delete message failed: $e");
      return ApiService.errorMessage(
        e,
        fallback: "Couldn't delete the message.",
      );
    }
  }

  /// A cache write that mustn't make a successful delete look like a failure.
  Future<void> _remember(Future<void> Function() write) async {
    try {
      await write();
    } catch (e) {
      debugPrint("Couldn't update the message cache: $e");
    }
  }

  /// Shows [messageId] in the open chat as deleted for everyone. Reactions,
  /// votes and replies that pointed at it carry on pointing at the tombstone.
  void applyDeletion(String messageId, DateTime at) {
    final index = activeChat.indexWhere(
      (m) => m.id.toLowerCase() == messageId.toLowerCase(),
    );
    if (index == -1 || activeChat[index].isDeleted) return;
    final updated = [...activeChat];
    updated[index] = updated[index].copyWith(content: '', deletedAt: at);
    activeChat = _withResolvedQuotes(updated);
    notifyListeners();
  }

  /// Removes [senderId]'s messages up to [upTo] from the open chat, after they
  /// deleted them for everyone.
  void removeMessagesFrom(String senderId, DateTime upTo) {
    // Compare IDs directly: isFrom() also matches our own "me" messages.
    final sender = senderId.trim().toLowerCase();
    final before = activeChat.length;
    activeChat = activeChat
        .where(
          (m) =>
              !(m.senderId.trim().toLowerCase() == sender &&
                  !m.createdAt.isAfter(upTo)),
        )
        .toList();
    if (activeChat.length != before) notifyListeners();
  }

  /// Empties the open chat, e.g. after its group was deleted.
  void clearOpenChat() {
    activeChat = [];
    notifyListeners();
  }

  bool _isMine(Message msg) => msg.isFrom(_myId);

  /// Plaintext byte budget for the open chat.
  int get messageByteLimit => isCurrentChatGroup
      ? ServerLimits.maxGroupMessageBytes
      : ServerLimits.maxDirectMessageBytes;

  // --- Loading ---

  Future<void> openChat(String targetUid, {bool isGroup = false}) async {
    if (targetUid.isEmpty || targetUid == 'null') return;
    final int requestId = ++_currentRequestId;

    if (currentChatUserId != targetUid) {
      activeChat = [];
      isChatHistoryLoading = true;
      hasMoreMessages = true;
      chatOpenCount = 0;
    }
    historyError = null;

    chatOpenCount++;
    currentChatUserId = targetUid;
    isCurrentChatGroup = isGroup;
    isPeerTyping = false;
    isPeerOnline = false;
    notifyListeners();

    try {
      final db = await DatabaseHelper.instance.database;
      final localData = await db.query(
        'messages',
        where: 'chat_id = ?',
        whereArgs: [targetUid],
        orderBy: 'created_at DESC',
        limit: ServerLimits.historyPageSize,
      );

      if (localData.isNotEmpty && currentChatUserId == targetUid) {
        activeChat = _withResolvedQuotes(
          localData.map(Message.fromRow).toList().reversed.toList(),
        );
        isChatHistoryLoading = false;
        notifyListeners();
      }
    } catch (e) {
      debugPrint("Local cache read failed: $e");
    }

    try {
      final res = await _api.getChatHistory(targetUid, isGroup: isGroup);
      if (requestId != _currentRequestId || currentChatUserId != targetUid) {
        return;
      }

      final page = await _decodeServerPage(
        targetUid,
        ApiService.dataList(res.data),
      );
      if (currentChatUserId != targetUid) return;

      hasMoreMessages = page.length >= ServerLimits.historyPageSize;
      _mergeLatestPage(page);
      await _cache(targetUid, page);

      _ws.sendReadReceipt(
        receiverId: isGroup ? null : targetUid,
        groupId: isGroup ? targetUid : null,
      );
      if (!isGroup) _ws.sendRequestStatus(targetId: targetUid);
    } catch (e) {
      debugPrint("Chat history fetch failed: $e");
      if (requestId == _currentRequestId && currentChatUserId == targetUid) {
        historyError = "Couldn't load messages";
        // Don't page further back until Try again: an older page would fail
        // too, and replace this error with a misleading one.
        hasMoreMessages = false;
      }
    } finally {
      if (currentChatUserId == targetUid) {
        isChatHistoryLoading = false;
        notifyListeners();
      }
    }
  }

  /// Clears the error, resets paging and loads the chat's latest page
  /// again. Older pages load again as the user scrolls up.
  Future<void> retryHistory() async {
    final target = currentChatUserId;
    if (target == null) return;
    historyError = null;
    hasMoreMessages = true;
    isChatHistoryLoading = activeChat.isEmpty;
    notifyListeners();
    await openChat(target, isGroup: isCurrentChatGroup);
  }

  Future<void> loadMoreMessages() async {
    if (isLoadingMore ||
        isChatHistoryLoading ||
        !hasMoreMessages ||
        currentChatUserId == null ||
        activeChat.isEmpty) {
      return;
    }

    isLoadingMore = true;
    notifyListeners();

    final targetUid = currentChatUserId!;
    try {
      final oldest = activeChat.firstWhere(
        (m) => !m.isPending,
        orElse: () => activeChat.first,
      );
      final res = await _api.getChatHistory(
        targetUid,
        isGroup: isCurrentChatGroup,
        before: oldest.createdAt.toUtc().toIso8601String(),
      );
      if (currentChatUserId != targetUid) return;

      final page = await _decodeServerPage(
        targetUid,
        ApiService.dataList(res.data),
      );
      if (currentChatUserId != targetUid) return;

      hasMoreMessages = page.length >= ServerLimits.historyPageSize;
      final knownIds = activeChat.map((m) => m.id).toSet();
      final older = page.where((m) => !knownIds.contains(m.id)).toList();
      activeChat = _withResolvedQuotes([...older, ...activeChat]);
      await _cache(targetUid, older);
    } catch (e) {
      debugPrint("Failed to load older messages: $e");
      // Stop paging until Try again (or the chat is reopened); otherwise the
      // rebuild below re-triggers this from the scroll listener in a tight
      // retry loop.
      hasMoreMessages = false;
      if (currentChatUserId == targetUid) {
        historyError = "Couldn't load older messages";
      }
    } finally {
      isLoadingMore = false;
      notifyListeners();
    }
  }

  /// Refetches the newest page, e.g. after resuming the app.
  Future<void> syncActiveChatSilently() async {
    final targetUid = currentChatUserId;
    if (targetUid == null) return;

    try {
      final res = await _api.getChatHistory(
        targetUid,
        isGroup: isCurrentChatGroup,
      );
      if (currentChatUserId != targetUid) return;

      final page = await _decodeServerPage(
        targetUid,
        ApiService.dataList(res.data),
      );
      if (currentChatUserId != targetUid) return;

      _mergeLatestPage(page);
      await _cache(targetUid, page);
      notifyListeners();
    } catch (e) {
      debugPrint("Silent chat sync failed: $e");
    }
  }

  /// Converts server rows to readable messages, reusing cached plaintext and
  /// only decrypting what is new or was edited since it was cached.
  Future<List<Message>> _decodeServerPage(
    String chatId,
    List<dynamic> rows,
  ) async {
    final db = await DatabaseHelper.instance.database;
    final cached = await db.query(
      'messages',
      where: 'chat_id = ?',
      whereArgs: [chatId],
    );
    final Map<String, Message> cachedById = {
      for (final row in cached) row['id'] as String: Message.fromRow(row),
    };

    final List<Message> result = [];
    // Server pages are newest-first; decrypt oldest-first to follow the ratchet.
    for (final json in rows.reversed) {
      final msg = Message.fromJson(Map<String, dynamic>.from(json));
      // Deleted for everyone: nothing to decrypt, and whatever we cached of it
      // has to go.
      if (msg.isDeleted) {
        result.add(msg.copyWith(content: ''));
        continue;
      }
      final local = cachedById[msg.id];
      final localIsReadable =
          local != null && !MessageEnvelope.isUnreadable(local.content);
      final editedSinceCache = Message.isNewerEdit(
        msg.editedAt,
        local?.editedAt,
      );

      String content;
      if (localIsReadable && !editedSinceCache) {
        content = local.content;
      } else if (_isMine(msg) &&
          !(MessageEnvelope.tryParse(msg.content)?.isPlaintext ?? true)) {
        // Our own DMs are encrypted for the recipient and can't be read back.
        content = localIsReadable
            ? local.content
            : MessageEnvelope.locked('Sent from another device');
      } else {
        content = await SignalService().decodeIncoming(
          msg.senderId,
          msg.content,
        );
      }

      result.add(msg.copyWith(content: content));
    }
    return result;
  }

  /// Replaces the newest window with [page] while keeping older loaded
  /// messages and unsent ones.
  void _mergeLatestPage(List<Message> page) {
    if (page.isEmpty) return;
    final pageIds = page.map((m) => m.id).toSet();
    final oldestInPage = page.first.createdAt;
    final newestInPage = page.last.createdAt;
    final outside = activeChat.where((m) => !pageIds.contains(m.id));

    final older = outside.where(
      (m) => !m.isPending && m.createdAt.isBefore(oldestInPage),
    );
    // Realtime messages the server hasn't persisted yet, plus unsent ones.
    final newer = outside.where(
      (m) => m.isPending || m.createdAt.isAfter(newestInPage),
    );

    activeChat = _withResolvedQuotes([...older, ...page, ...newer]);
  }

  Future<void> _cache(String chatId, List<Message> messages) async {
    try {
      final db = await DatabaseHelper.instance.database;
      final batch = db.batch();
      for (final msg in messages) {
        if (MessageEnvelope.isUnreadable(msg.content)) continue;
        batch.insert(
          'messages',
          msg.toRow(chatId),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    } catch (e) {
      debugPrint("Failed to cache messages: $e");
    }
  }

  /// Fills reply previews with readable text from the loaded conversation,
  /// since the server quotes the raw (possibly encrypted) content.
  List<Message> _withResolvedQuotes(List<Message> messages) {
    final byId = {for (final m in messages) m.id: m};
    return messages.map((msg) {
      final replyId = msg.replyToMessageId;
      if (replyId == null) return msg;

      final original = byId[replyId];
      if (original != null) {
        return msg.copyWith(
          quotedMessage: QuotedMessage(
            id: replyId,
            senderId: original.senderId,
            senderDisplayName: msg.quotedMessage?.senderDisplayName ?? '',
            content: original.text,
          ),
        );
      }
      final quoted = msg.quotedMessage;
      if (quoted == null) return msg;
      return msg.copyWith(
        quotedMessage: quoted.copyWith(
          content: MessageEnvelope.preview(quoted.content),
        ),
      );
    }).toList();
  }

  // --- Sending ---

  /// Sends a message. Returns an error to show the user, or null on success.
  ///
  /// With a [preview] of a link in [text], it goes along inside the message,
  /// unless that would make the message too long: then it is left out.
  Future<String?> sendTextMessage(
    String text, {
    Message? replyingTo,
    LinkPreview? preview,
  }) async {
    final targetId = currentChatUserId;
    if (targetId == null) return null;
    var content = text;
    if (preview != null) {
      final withPreview = MessagePayload.encode(
        'preview',
        preview.toData(),
        text: text,
      );
      if (utf8.encode(withPreview).length <= messageByteLimit) {
        content = withPreview;
      }
    }
    final (error, _) = await sendTo(
      targetId,
      isGroup: isCurrentChatGroup,
      text: content,
      replyingTo: replyingTo,
    );
    return error;
  }

  /// Sends a structured message to the open chat: [text] for apps that don't
  /// know [kind], and [data] for ones that do. Actions are sent silently.
  /// Returns an error to show, or null.
  Future<String?> sendPayload(
    String kind,
    Map<String, dynamic> data, {
    required String text,
    Message? replyingTo,
  }) async {
    final targetId = currentChatUserId;
    if (targetId == null) return null;
    final (error, _) = await sendTo(
      targetId,
      isGroup: isCurrentChatGroup,
      text: MessagePayload.encode(kind, data, text: text),
      replyingTo: replyingTo,
      silent: MessagePayload.actionKinds.contains(kind),
    );
    return error;
  }

  /// Shares [location] in the open chat.
  Future<String?> sendLocation(SharedLocation location) {
    final (data, text) = location.toPayload();
    return sendPayload('location', data, text: text);
  }

  /// Shares [contact] in the open chat.
  Future<String?> sendContact(SharedContact contact) {
    final (data, text) = contact.toPayload();
    return sendPayload('contact', data, text: text);
  }

  /// Sends a poll to the open chat.
  Future<String?> sendPoll(PollData poll) {
    final (data, text) = poll.toPayload();
    return sendPayload('poll', data, text: text);
  }

  /// Votes in [poll] (a message in the open chat) for [options], replacing
  /// any earlier vote. An empty set takes the vote back.
  Future<String?> vote(Message poll, Set<int> options) {
    final (data, text) = votePayload(poll.id, options);
    return sendPayload('vote', data, text: text);
  }

  /// Pins or unpins [message] in the open chat for everyone in it.
  Future<String?> setPinned(Message message, bool pinned) {
    if (!canPin) {
      return Future.value('Only admins can pin messages.');
    }
    final (data, text) = ChatMeta.pinPayload(message.id, pinned);
    return sendPayload('pin', data, text: text);
  }

  /// Reacts to [message] with [emoji] in the open chat. Reacting with the
  /// emoji already chosen takes the reaction away.
  Future<String?> react(Message message, String emoji) {
    final chosen = meta.myReactionTo(message.id) == emoji ? '' : emoji;
    final (data, text) = ChatMeta.reactionPayload(message.id, chosen);
    return sendPayload('reaction', data, text: text);
  }

  /// Forwards [text] to each chat in [targets] (chat ID → is a group) as a
  /// new message: encrypted separately for each direct chat, never a copy of
  /// someone's ciphertext. Returns the chats it couldn't be sent to, with why.
  Future<Map<String, String>> forward(
    String text,
    Map<String, bool> targets,
  ) async {
    final failed = <String, String>{};
    for (final MapEntry(key: chatId, value: isGroup) in targets.entries) {
      // One chat failing mustn't stop the others.
      try {
        final (error, _) = await sendTo(chatId, isGroup: isGroup, text: text);
        if (error != null) failed[chatId] = error;
      } catch (e) {
        debugPrint("Forward to $chatId failed: $e");
        failed[chatId] = "Couldn't send the message.";
      }
    }
    return failed;
  }

  /// Encrypts (for a direct chat), queues and sends [text] to [targetId]. If
  /// that chat is open, the message appears in it straight away. Returns an
  /// error to show, or the message that was queued.
  ///
  /// A [silent] message carries an action (see [MessagePayload]): the server
  /// doesn't count it as unread or ping anyone for it.
  Future<(String?, Message?)> sendTo(
    String targetId, {
    required bool isGroup,
    required String text,
    Message? replyingTo,
    bool silent = false,
  }) async {
    final cleanContent = text.trim();
    if (cleanContent.isEmpty) return (null, null);

    final byteLimit = isGroup
        ? ServerLimits.maxGroupMessageBytes
        : ServerLimits.maxDirectMessageBytes;
    if (utf8.encode(cleanContent).length > byteLimit) {
      return ('Message is too long.', null);
    }

    String securePayload;
    if (isGroup) {
      securePayload = MessageEnvelope.plain(cleanContent);
    } else {
      final sessionReady = await SignalService().establishSessionIfNeeded(
        targetId,
      );
      if (!sessionReady) {
        return (
          "This contact hasn't set up encryption yet. Try again once they've opened Elephant.",
          null,
        );
      }
      try {
        securePayload = await SignalService().encryptDirect(
          targetId,
          cleanContent,
        );
      } catch (e) {
        debugPrint("Encryption failed: $e");
        return (
          "Couldn't encrypt this message. Try resetting the secure session.",
          null,
        );
      }
    }

    final clientMessageId = _uuid.v4();
    final frame = WebSocketService.chatFrame(
      messageId: clientMessageId,
      receiverId: isGroup ? null : targetId,
      groupId: isGroup ? targetId : null,
      content: securePayload,
      replyToMessageId: replyingTo?.id,
      silent: silent,
    );
    if (WebSocketService.frameSize(frame) > ServerLimits.maxWsFrameBytes) {
      return ('Message is too long.', null);
    }

    final optimisticMsg = Message(
      id: clientMessageId,
      senderId: "me",
      receiverId: targetId,
      content: cleanContent,
      createdAt: DateTime.now(),
      isRead: false,
      replyToMessageId: replyingTo?.id,
      quotedMessage: replyingTo == null
          ? null
          : QuotedMessage(
              id: replyingTo.id,
              senderId: replyingTo.senderId,
              senderDisplayName: '',
              content: replyingTo.text,
            ),
      syncStatus: 'pending',
    );

    if (currentChatUserId == targetId) {
      activeChat = [...activeChat, optimisticMsg];
      notifyListeners();
    }

    try {
      await DatabaseHelper.instance.insertMessage(
        optimisticMsg.toRow(targetId),
      );
      await DatabaseHelper.instance.queueAction(
        clientMessageId,
        isGroup ? 'send_group_chat' : 'send_chat',
        {
          'messageId': clientMessageId,
          'receiverId': isGroup ? null : targetId,
          'groupId': isGroup ? targetId : null,
          'content': securePayload,
          'replyToMessageId': replyingTo?.id,
          'silent': silent,
        },
      );

      if (_ws.emit(frame)) {
        await markMessageAsSynced(clientMessageId);
      }
    } catch (e) {
      debugPrint("Immediate send failed, message stays queued: $e");
    }
    return (null, optimisticMsg);
  }

  /// Edits one of our messages via `PUT /api/messages/{id}`. Returns an error
  /// to show, or null on success. The other side sees the edit on next sync.
  Future<String?> editMessage(Message msg, String newText) async {
    final targetId = currentChatUserId;
    final text = newText.trim();
    if (targetId == null || text.isEmpty) return null;
    if (text == msg.content) return null;
    if (!msg.canEdit(_myId)) {
      return 'Messages can only be edited for 15 minutes after sending.';
    }
    if (utf8.encode(text).length > messageByteLimit) {
      return 'Message is too long.';
    }

    try {
      final String content;
      if (isCurrentChatGroup) {
        content = MessageEnvelope.plain(text);
      } else {
        if (!await SignalService().establishSessionIfNeeded(targetId)) {
          return "Couldn't reach this contact's encryption keys.";
        }
        content = await SignalService().encryptDirect(targetId, text);
      }

      final res = await _api.editMessage(msg.id, content);
      final editedAt =
          Message.fromJson(ApiService.dataMap(res.data)).editedAt ??
          DateTime.now();

      final updated = msg.copyWith(content: text, editedAt: editedAt);
      activeChat = _withResolvedQuotes(
        activeChat.map((m) => m.id == msg.id ? updated : m).toList(),
      );
      notifyListeners();

      final db = await DatabaseHelper.instance.database;
      await db.update(
        'messages',
        {'content': text, 'edited_at': editedAt.millisecondsSinceEpoch},
        where: 'id = ?',
        whereArgs: [msg.id],
      );
      await onMessageEdited?.call(targetId, msg.id, text);
      return null;
    } catch (e) {
      debugPrint("Edit message failed: $e");
      return ApiService.errorMessage(e, fallback: "Couldn't edit the message.");
    }
  }

  void sendTypingNotification(bool typing) {
    final target = currentChatUserId;
    if (target == null) return;
    _ws.sendTyping(
      receiverId: isCurrentChatGroup ? null : target,
      groupId: isCurrentChatGroup ? target : null,
      isTyping: typing,
    );
  }

  // --- Realtime updates (called by ChatEventHandler) ---

  void receiveIncoming(Message msg) {
    if (activeChat.any((m) => m.id == msg.id)) return;
    activeChat = _withResolvedQuotes([...activeChat, msg]);
    isPeerTyping = false;
    notifyListeners();
  }

  /// The peer read our messages.
  void applyReadReceipt() {
    bool changed = false;
    activeChat = activeChat.map((m) {
      if (_isMine(m) && !m.isRead) {
        changed = true;
        return m.copyWith(isRead: true);
      }
      return m;
    }).toList();
    if (changed) notifyListeners();
  }

  Future<void> markMessageAsSynced(String messageId) async {
    final index = activeChat.indexWhere((m) => m.id == messageId);
    if (index != -1) {
      final newList = List<Message>.from(activeChat);
      newList[index] = newList[index].copyWith(syncStatus: 'synced');
      activeChat = newList;
      notifyListeners();
    }

    try {
      final db = await DatabaseHelper.instance.database;
      await db.update(
        'messages',
        {'sync_status': 'synced'},
        where: 'id = ?',
        whereArgs: [messageId],
      );
      await db.delete('action_queue', where: 'id = ?', whereArgs: [messageId]);
    } catch (e) {
      debugPrint("Failed to update DB sync status: $e");
    }
  }

  void closeChat(String closedChatId) {
    if (currentChatUserId != closedChatId) return;
    chatOpenCount--;
    if (chatOpenCount <= 0) {
      currentChatUserId = null;
      isPeerTyping = false;
      isPeerOnline = false;
      activeChat = [];
      chatOpenCount = 0;
    }
    notifyListeners();
  }

  /// Every cached message of a chat, oldest first, for in-chat search.
  Future<List<Message>> getLocalMessagesForChat(String chatId) async {
    try {
      final db = await DatabaseHelper.instance.database;
      final rows = await db.query(
        'messages',
        where: 'chat_id = ? COLLATE NOCASE',
        whereArgs: [chatId],
        orderBy: 'created_at ASC',
      );
      return rows
          .map(Message.fromRow)
          .where((m) => !MessageEnvelope.isUnreadable(m.content))
          .toList();
    } catch (e) {
      debugPrint("Error reading local messages: $e");
      return [];
    }
  }
}

/// [chat] with the message [messageId] replaced by its edited version, or [chat]
/// itself if there is no such message.
@visibleForTesting
List<Message> withEditApplied(
  List<Message> chat,
  String messageId,
  String content,
  DateTime editedAt,
) {
  final id = messageId.toLowerCase();
  if (!chat.any((m) => m.id.toLowerCase() == id)) return chat;
  return [
    for (final m in chat)
      m.id.toLowerCase() == id
          ? m.copyWith(content: content, editedAt: editedAt)
          : m,
  ];
}
