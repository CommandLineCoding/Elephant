import 'package:flutter/material.dart';
import 'package:mobile/controllers/call/call_controller.dart';
import 'package:mobile/core/message_envelope.dart';
import 'package:mobile/services/signal_service.dart';
import 'package:mobile/controllers/chat/active_chat_controller.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import '../../models/message.dart';
import '../db_services.dart';
import '../../services/ws_service.dart';

/// Applies server → client WebSocket events (see docs/API_CONTRACTS.md) to
/// the local database, the inbox and the open chat.
class ChatEventHandler {
  final InboxController inboxController;
  final ActiveChatController activeChatController;
  final String Function() currentUserIdProvider;
  final WebSocketService _ws = WebSocketService();

  /// Tells the server direct messages reached this phone. Tests replace it.
  late final void Function(List<String> messageIds) acknowledge;

  ChatEventHandler({
    required this.inboxController,
    required this.activeChatController,
    required this.currentUserIdProvider,
    void Function(List<String> messageIds)? acknowledge,
  }) {
    this.acknowledge = acknowledge ?? _ws.sendDelivered;
  }

  String get currentUserId => currentUserIdProvider();

  /// The server sends `""` instead of omitting unused IDs in some events.
  static String? _id(dynamic value) {
    final text = value?.toString().trim();
    return (text == null || text.isEmpty) ? null : text.toLowerCase();
  }

  /// The conversation an event belongs to: the group, or the other user.
  String? _chatIdFor(Map<String, dynamic> data) {
    final groupId = _id(data['group_id']);
    if (groupId != null) return groupId;

    final senderId = _id(data['sender_id']);
    final receiverId = _id(data['receiver_id']);
    final myId = currentUserId.trim().toLowerCase();
    return senderId == myId ? receiverId : senderId;
  }

  bool _isOpen(String? chatId) {
    final open = activeChatController.currentChatUserId?.trim().toLowerCase();
    return chatId != null && open != null && open == chatId;
  }

  Future<void> handleIncomingEvent(Map<String, dynamic> data) async {
    final type = data['type'];
    if (type is String && type.startsWith('call_')) {
      await CallController.instance?.handleEvent(data);
      return;
    }
    switch (type) {
      case 'user_status':
        final userId = _id(data['user_id']);
        if (!activeChatController.isCurrentChatGroup && _isOpen(userId)) {
          activeChatController.isPeerOnline = data['online'] == true;
          if (!activeChatController.isPeerOnline) {
            activeChatController.isPeerTyping = false;
          }
          activeChatController.refreshUI();
        }
        break;

      case 'chat':
        await _handleChat(data);
        break;

      case 'typing':
        if (_isOpen(_chatIdFor(data))) {
          final nowTyping =
              data['content'] == 'true' || data['content'] == true;
          if (activeChatController.isPeerTyping != nowTyping) {
            activeChatController.isPeerTyping = nowTyping;
            activeChatController.refreshUI();
          }
        }
        break;

      case 'read_receipt':
        await _handleReadReceipt(data);
        break;

      case 'message_edited':
        await _handleMessageEdited(data);
        break;

      case 'messages_deleted':
        await _handleMessagesDeleted(data);
        break;

      case 'message_deleted':
        await _handleMessageDeleted(data);
        break;

      case 'message_delivered':
        await _handleDelivered(data);
        break;

      case 'group_deleted':
        await _handleGroupDeleted(data);
        break;
    }
  }

  /// Messages we sent reached the other person's phone.
  Future<void> _handleDelivered(Map<String, dynamic> data) async {
    final raw = data['message_ids'];
    final peerId = _id(data['receiver_id']);
    if (raw is! List || peerId == null) return;
    final ids = [
      for (final id in raw)
        if (id is String && id.isNotEmpty) id,
    ];
    if (ids.isEmpty) return;
    final at =
        DateTime.tryParse(data['delivered_at']?.toString() ?? '')?.toLocal() ??
        DateTime.now();

    if (_isOpen(peerId)) activeChatController.applyDelivered(ids, at);
    try {
      await DatabaseHelper.instance.markMessagesDelivered(ids, at);
    } catch (e) {
      debugPrint("Couldn't save delivered messages: $e");
    }
  }

  /// Someone deleted one of their messages for everyone.
  Future<void> _handleMessageDeleted(Map<String, dynamic> data) async {
    final chatId = _chatIdFor(data);
    final messageId = data['message_id']?.toString() ?? '';
    final senderId = data['sender_id']?.toString() ?? '';
    if (chatId == null || messageId.isEmpty || senderId.isEmpty) return;
    if (_id(senderId) == currentUserId.trim().toLowerCase()) return;

    final at =
        DateTime.tryParse(data['deleted_at']?.toString() ?? '')?.toLocal() ??
        DateTime.now();
    // Update the screen first: a cache error shouldn't leave it on show.
    if (_isOpen(chatId)) activeChatController.applyDeletion(messageId, at);
    try {
      await DatabaseHelper.instance.markMessageDeleted(messageId, at);
    } catch (e) {
      debugPrint("Couldn't mark a message deleted in the cache: $e");
    }
    // It may have been the chat's last message.
    await inboxController.loadInbox();
  }

  /// The other person in a direct chat deleted the messages they sent us, up
  /// to `before`.
  Future<void> _handleMessagesDeleted(Map<String, dynamic> data) async {
    final senderId = data['sender_id']?.toString() ?? '';
    final before = DateTime.tryParse(data['before']?.toString() ?? '');
    if (senderId.isEmpty || before == null) return;
    if (_id(senderId) == currentUserId.trim().toLowerCase()) return;

    final chatId = _id(senderId)!;
    // Update the screen first: a cache error shouldn't leave deleted messages
    // on show.
    if (_isOpen(chatId)) {
      activeChatController.removeMessagesFrom(senderId, before);
    }
    try {
      await DatabaseHelper.instance.deleteMessagesUpTo(
        chatId,
        before,
        fromSender: senderId,
      );
    } catch (e) {
      debugPrint("Couldn't remove deleted messages from the cache: $e");
    }
    // The chat's last message may have been one of them.
    await inboxController.loadInbox();
  }

  /// An admin deleted a group we're in.
  Future<void> _handleGroupDeleted(Map<String, dynamic> data) async {
    final groupId = _id(data['group_id']);
    if (groupId == null) return;
    if (_isOpen(groupId)) activeChatController.clearOpenChat();
    try {
      await inboxController.removeChat(groupId);
    } catch (e) {
      debugPrint("Couldn't remove a deleted group from the cache: $e");
    }
  }

  /// Someone edited a message in a conversation we're in.
  Future<void> _handleMessageEdited(Map<String, dynamic> data) async {
    final chatId = _chatIdFor(data);
    final messageId = data['message_id']?.toString() ?? '';
    final senderId = data['sender_id']?.toString() ?? '';
    if (chatId == null || messageId.isEmpty || senderId.isEmpty) return;
    if (_id(senderId) == currentUserId.trim().toLowerCase()) return;

    // The new text is encrypted like any message, so it is decrypted once, here.
    final content = await SignalService().decodeIncoming(
      senderId,
      data['content']?.toString() ?? '',
    );
    // If it can't be read, keep the text we have rather than replace it with a
    // placeholder. The edit still shows up the next time history is loaded.
    if (MessageEnvelope.isUnreadable(content)) return;

    // Stored with the server's own timestamp, so the same edit coming back in a
    // history page is recognised and isn't decrypted again.
    final editedAt =
        DateTime.tryParse(data['edited_at']?.toString() ?? '')?.toLocal() ??
        DateTime.now();

    try {
      final db = await DatabaseHelper.instance.database;
      await db.update(
        'messages',
        {'content': content, 'edited_at': editedAt.millisecondsSinceEpoch},
        where: 'id = ? COLLATE NOCASE',
        whereArgs: [messageId],
      );
    } catch (e) {
      debugPrint("Failed to save an edited message: $e");
    }

    if (_isOpen(chatId)) {
      activeChatController.applyRemoteEdit(messageId, content, editedAt);
    }
    await inboxController.updatePreviewForEdit(chatId, messageId, content);
  }

  Future<void> _handleChat(Map<String, dynamic> data) async {
    final chatId = _chatIdFor(data);
    final senderId = data['sender_id']?.toString() ?? '';
    if (chatId == null || senderId.isEmpty) return;

    final rawContent = data['content']?.toString() ?? '';
    final content = await SignalService().decodeIncoming(senderId, rawContent);

    final isOpen = _isOpen(chatId);
    var message = Message.fromJson(
      data,
    ).copyWith(content: content, isRead: isOpen);

    // A direct message reached this phone: say so, for the sender's tick.
    if (_id(data['group_id']) == null && message.id.isNotEmpty) {
      acknowledge([message.id]);
    }

    // An action (a reaction, a vote, a pin) is kept and applied, but it isn't
    // a new message: nothing unread, no read receipt, no new chat list line.
    if (message.isAction) {
      message = message.copyWith(isRead: true);
      try {
        await DatabaseHelper.instance.insertMessage(message.toRow(chatId));
      } catch (e) {
        debugPrint("Failed to save an incoming action: $e");
      }
      if (isOpen) activeChatController.receiveIncoming(message);
      return;
    }

    try {
      await DatabaseHelper.instance.insertMessage(message.toRow(chatId));
    } catch (e) {
      debugPrint("Failed to save incoming message: $e");
    }

    if (isOpen) {
      activeChatController.receiveIncoming(message);
      final isGroup = activeChatController.isCurrentChatGroup;
      _ws.sendReadReceipt(
        receiverId: isGroup ? null : senderId,
        groupId: isGroup ? chatId : null,
      );
    }

    inboxController.updateLocalInboxState(
      chatId,
      MessageEnvelope.isUnreadable(content)
          ? '🔒 Encrypted message'
          : message.text,
      message.createdAt,
      !isOpen,
      senderId: senderId,
      syncStatus: 'synced',
      isRead: isOpen,
    );
  }

  Future<void> _handleReadReceipt(Map<String, dynamic> data) async {
    final readerId = _id(data['sender_id']);
    final myId = currentUserId.trim().toLowerCase();
    if (readerId == null || readerId == myId) return;

    final chatId = _chatIdFor(data);
    if (chatId == null) return;

    try {
      final db = await DatabaseHelper.instance.database;
      await db.update(
        'messages',
        {'is_read': 1},
        where:
            'chat_id = ? COLLATE NOCASE AND (sender_id = ? OR sender_id = ?)',
        whereArgs: [chatId, 'me', currentUserId],
      );
      inboxController.markInboxItemAsRead(chatId);
    } catch (e) {
      debugPrint("Failed to apply read receipt: $e");
    }

    if (_isOpen(chatId)) activeChatController.applyReadReceipt();
  }
}
