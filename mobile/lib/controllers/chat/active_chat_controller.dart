import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:mobile/core/constants.dart';
import 'package:mobile/core/message_envelope.dart';
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
  int _currentRequestId = 0;
  List<Message> activeChat = [];
  String? currentChatUserId;
  bool isPeerTyping = false;
  bool isPeerOnline = false;
  bool isChatHistoryLoading = false;
  bool isCurrentChatGroup = false;
  int chatOpenCount = 0;

  void refreshUI() => notifyListeners();

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
    } finally {
      if (currentChatUserId == targetUid) {
        isChatHistoryLoading = false;
        notifyListeners();
      }
    }
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
      final local = cachedById[msg.id];
      final localIsReadable =
          local != null && !MessageEnvelope.isUnreadable(local.content);
      final editedSinceCache =
          msg.editedAt != null &&
          (local?.editedAt == null || msg.editedAt!.isAfter(local!.editedAt!));

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
            content: original.content,
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
  Future<String?> sendTextMessage(String text, {Message? replyingTo}) async {
    final cleanContent = text.trim();
    final targetId = currentChatUserId;
    if (targetId == null || cleanContent.isEmpty) return null;

    if (utf8.encode(cleanContent).length > messageByteLimit) {
      return 'Message is too long.';
    }

    final isGroup = isCurrentChatGroup;
    String securePayload;
    if (isGroup) {
      securePayload = MessageEnvelope.plain(cleanContent);
    } else {
      final sessionReady = await SignalService().establishSessionIfNeeded(
        targetId,
      );
      if (!sessionReady) {
        return "This contact hasn't set up encryption yet. Try again once they've opened Elephant.";
      }
      try {
        securePayload = await SignalService().encryptDirect(
          targetId,
          cleanContent,
        );
      } catch (e) {
        debugPrint("Encryption failed: $e");
        return "Couldn't encrypt this message. Try resetting the secure session.";
      }
    }

    final clientMessageId = _uuid.v4();
    final frame = WebSocketService.chatFrame(
      messageId: clientMessageId,
      receiverId: isGroup ? null : targetId,
      groupId: isGroup ? targetId : null,
      content: securePayload,
      replyToMessageId: replyingTo?.id,
    );
    if (WebSocketService.frameSize(frame) > ServerLimits.maxWsFrameBytes) {
      return 'Message is too long.';
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
              content: replyingTo.content,
            ),
      syncStatus: 'pending',
    );

    activeChat = [...activeChat, optimisticMsg];
    notifyListeners();

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
        },
      );

      if (_ws.emit(frame)) {
        await markMessageAsSynced(clientMessageId);
      }
    } catch (e) {
      debugPrint("Immediate send failed, message stays queued: $e");
    }
    return null;
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
      return null;
    } catch (e) {
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
