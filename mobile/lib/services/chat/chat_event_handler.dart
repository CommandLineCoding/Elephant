import 'package:flutter/material.dart';
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

  ChatEventHandler({
    required this.inboxController,
    required this.activeChatController,
    required this.currentUserIdProvider,
  });

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
    switch (data['type']) {
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
    }
  }

  Future<void> _handleChat(Map<String, dynamic> data) async {
    final chatId = _chatIdFor(data);
    final senderId = data['sender_id']?.toString() ?? '';
    if (chatId == null || senderId.isEmpty) return;

    final rawContent = data['content']?.toString() ?? '';
    final content = await SignalService().decodeIncoming(senderId, rawContent);

    final isOpen = _isOpen(chatId);
    final message = Message.fromJson(
      data,
    ).copyWith(content: content, isRead: isOpen);

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
      MessageEnvelope.isUnreadable(content) ? '🔒 Encrypted message' : content,
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
