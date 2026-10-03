import 'dart:async';
import 'package:flutter/material.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import '../../core/message_envelope.dart';
import '../../models/group.dart';
import '../../models/inbox_item.dart';
import '../../services/api_services.dart';
import '../../services/db_services.dart';
import '../../services/ws_service.dart';

class InboxController extends ChangeNotifier {
  final ApiService _api = ApiService();
  List<InboxItem> inbox = [];
  bool isLoading = false;
  bool hasLoadedOnce = false;

  List<InboxItem> get groups => inbox.where((item) => item.isGroup).toList();
  int get unreadChats => inbox.where((item) => item.unreadCount > 0).length;

  void clearInbox() {
    inbox = [];
    hasLoadedOnce = false;
    notifyListeners();
  }

  Future<void> loadInbox({
    bool isOffline = false,
    String? currentChatId,
  }) async {
    try {
      final db = await DatabaseHelper.instance.database;
      final localData = await db.query('inbox', orderBy: 'timestamp DESC');
      if (localData.isNotEmpty && inbox.isEmpty) {
        inbox = localData.map(InboxItem.fromMap).toList();
        notifyListeners();
      }
    } catch (e) {
      debugPrint("Failed to load local inbox cache: $e");
    }

    if (isOffline) return;

    isLoading = true;
    notifyListeners();

    try {
      final results = await Future.wait([
        _api.getConversations(),
        _api.getGroups(),
      ]);
      final conversations = ApiService.dataList(results[0].data);
      final myGroups = ApiService.dataList(
        results[1].data,
      ).map((json) => Group.fromJson(Map<String, dynamic>.from(json))).toList();

      final latestLocal = await _latestReadableMessages();

      final List<InboxItem> combined = [];
      for (final raw in conversations) {
        final json = Map<String, dynamic>.from(raw);
        final id = json['id']?.toString() ?? '';
        if (id.isEmpty) continue;

        final serverPreview = json['last_message']?.toString() ?? '';
        String preview = MessageEnvelope.preview(serverPreview, fallback: '');
        if (preview.isEmpty) {
          preview = latestLocal[id] ?? '🔒 Encrypted message';
        }
        combined.add(
          InboxItem.fromConversationJson(json, lastMessage: preview),
        );
      }

      // Groups without messages are missing from the conversations list.
      final knownIds = combined.map((item) => item.id).toSet();
      for (final group in myGroups) {
        if (!knownIds.contains(group.id)) {
          combined.add(InboxItem.fromGroup(group));
        }
      }

      combined.sort((a, b) => b.timestamp.compareTo(a.timestamp));

      final chatsToCatchUp = combined.where((fresh) {
        final old = inbox.where((c) => c.id == fresh.id).firstOrNull;
        return old == null || old.timestamp.isBefore(fresh.timestamp);
      }).toList();

      inbox = combined;
      hasLoadedOnce = true;
      await _replaceInboxInDb(inbox);

      for (final chat in chatsToCatchUp) {
        if (chat.id != currentChatId && chat.lastMessage.isNotEmpty) {
          unawaited(_backgroundSyncChatHistoryToDb(chat.id, chat.isGroup));
        }
      }
    } catch (e) {
      debugPrint("Inbox fetch failed: $e");
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  /// Latest cached plaintext per chat, used when the server preview is ciphertext.
  Future<Map<String, String>> _latestReadableMessages() async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.rawQuery(
      '''
      SELECT m.chat_id, m.content
      FROM messages m
      JOIN (
        SELECT chat_id, MAX(created_at) AS latest
        FROM messages
        WHERE content NOT LIKE '%"ciphertext"%' AND content NOT LIKE ?
        GROUP BY chat_id
      ) l ON l.chat_id = m.chat_id AND l.latest = m.created_at
    ''',
      ['${MessageEnvelope.lockedPrefix}%'],
    );
    return {
      for (final row in rows)
        row['chat_id'].toString(): row['content'].toString(),
    };
  }

  void updateLocalInboxState(
    String chatId,
    String lastMessage,
    DateTime timestamp,
    bool incrementUnread, {
    String? senderId,
    String syncStatus = 'synced',
    bool isRead = false,
  }) {
    final int index = inbox.indexWhere((item) => item.id == chatId);
    if (index == -1) {
      unawaited(loadInbox());
      return;
    }

    final item = inbox.removeAt(index);
    item.lastMessage = lastMessage;
    item.timestamp = timestamp;
    item.lastMessageSender = senderId;
    item.lastMessageSyncStatus = syncStatus;
    item.lastMessageIsRead = isRead;
    if (incrementUnread) item.unreadCount += 1;
    inbox.insert(0, item);
    notifyListeners();

    _saveItem(item);
  }

  /// Our last message in [chatId] was read by the other side.
  void markInboxItemAsRead(String chatId) {
    final index = inbox.indexWhere((item) => item.id == chatId);
    if (index == -1) return;
    inbox[index].lastMessageIsRead = true;
    notifyListeners();
    _saveItem(inbox[index]);
  }

  /// We opened [chatId], so its unread badge goes away.
  void clearUnread(String chatId) {
    final index = inbox.indexWhere((item) => item.id == chatId);
    if (index == -1 || inbox[index].unreadCount == 0) return;
    inbox[index].unreadCount = 0;
    notifyListeners();
    _saveItem(inbox[index]);
  }

  /// Marks one conversation read on the server and locally.
  Future<void> markReadFor(InboxItem item) async {
    final ws = WebSocketService();
    try {
      if (item.isGroup) {
        ws.sendReadReceipt(groupId: item.id);
      } else {
        await _api.markDirectRead(item.id);
        ws.sendReadReceipt(receiverId: item.id);
      }
      clearUnread(item.id);
    } catch (e) {
      debugPrint("Failed to mark ${item.id} read: $e");
    }
  }

  Future<void> markAllRead() async {
    final unread = inbox.where((item) => item.unreadCount > 0).toList();
    await Future.wait(unread.map(markReadFor));
  }

  void renameLocal(String chatId, String newTitle) {
    final index = inbox.indexWhere((item) => item.id == chatId);
    if (index == -1) return;
    inbox[index] = inbox[index].copyWith(title: newTitle);
    notifyListeners();
    _saveItem(inbox[index]);
  }

  Future<void> removeChat(String chatId) async {
    inbox.removeWhere((item) => item.id == chatId);
    notifyListeners();
    await DatabaseHelper.instance.deleteChat(chatId);
  }

  void _saveItem(InboxItem item) {
    DatabaseHelper.instance.database.then((db) {
      db.insert(
        'inbox',
        item.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  Future<void> _backgroundSyncChatHistoryToDb(
    String chatId,
    bool isGroup,
  ) async {
    // Only plaintext (group) content can be cached without touching the
    // Signal ratchet; direct messages are decrypted when the chat is opened.
    if (!isGroup) return;
    try {
      final res = await _api.getChatHistory(chatId, isGroup: true);
      final db = await DatabaseHelper.instance.database;
      final batch = db.batch();
      for (final raw in ApiService.dataList(res.data)) {
        final json = Map<String, dynamic>.from(raw);
        final envelope = MessageEnvelope.tryParse(json['content']?.toString());
        if (envelope != null && !envelope.isPlaintext) continue;

        batch.insert('messages', {
          'id': json['id'],
          'chat_id': chatId,
          'sender_id': json['sender_id'],
          'content': envelope?.body ?? json['content'],
          'created_at': DateTime.parse(
            json['created_at'],
          ).millisecondsSinceEpoch,
          'is_read': 0,
          'reply_to_id': json['reply_to_message_id'],
          'sync_status': 'synced',
          'edited_at': json['edited_at'] != null
              ? DateTime.parse(json['edited_at']).millisecondsSinceEpoch
              : null,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      await batch.commit(noResult: true);
    } catch (e) {
      debugPrint("Background sync failed for $chatId: $e");
    }
  }

  Future<void> _replaceInboxInDb(List<InboxItem> items) async {
    try {
      final db = await DatabaseHelper.instance.database;
      final batch = db.batch();
      batch.delete('inbox');
      for (final item in items) {
        batch.insert(
          'inbox',
          item.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    } catch (e) {
      debugPrint("Failed to save inbox to DB: $e");
    }
  }
}
