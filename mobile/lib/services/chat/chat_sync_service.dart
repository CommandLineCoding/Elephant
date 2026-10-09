import 'dart:convert';
import 'package:flutter/material.dart';
import '../../controllers/chat/active_chat_controller.dart';
import '../../services/ws_service.dart';
import '../db_services.dart';

/// Replays messages that were written while the socket was down.
class ChatSyncService {
  final WebSocketService _ws = WebSocketService();
  bool _isSyncing = false;

  static const int _maxRetries = 5;

  Future<void> processOfflineQueue(
    String currentUserId, {
    ActiveChatController? activeChatController,
  }) async {
    if (_isSyncing || !_ws.isConnected) return;
    _isSyncing = true;

    try {
      final db = await DatabaseHelper.instance.database;
      final pendingActions = await db.query(
        'action_queue',
        where: 'retry_count < ?',
        whereArgs: [_maxRetries],
        orderBy: 'created_at ASC',
      );

      for (final action in pendingActions) {
        if (!_ws.isConnected) break;

        final actionId = action['id'] as String;
        final type = action['action_type'] as String;
        final payload = jsonDecode(action['payload'] as String);

        bool sent = false;
        if (type == 'send_chat') {
          sent = _ws.sendChat(
            messageId: payload['messageId'],
            receiverId: payload['receiverId'],
            content: payload['content'],
            replyToMessageId: payload['replyToMessageId'],
          );
        } else if (type == 'send_group_chat') {
          sent = _ws.sendGroupChat(
            messageId: payload['messageId'],
            groupId: payload['groupId'],
            content: payload['content'],
            replyToMessageId: payload['replyToMessageId'],
          );
        }

        if (sent) {
          await db.update(
            'messages',
            {'sync_status': 'synced'},
            where: 'id = ?',
            whereArgs: [actionId],
          );
          await db.delete(
            'action_queue',
            where: 'id = ?',
            whereArgs: [actionId],
          );
          activeChatController?.markMessageAsSynced(actionId);
          await Future.delayed(const Duration(milliseconds: 50));
        } else {
          await db.rawUpdate(
            'UPDATE action_queue SET retry_count = retry_count + 1 WHERE id = ?',
            [actionId],
          );
          debugPrint("Queued message $actionId could not be sent");
        }
      }
    } finally {
      _isSyncing = false;
    }
  }
}
