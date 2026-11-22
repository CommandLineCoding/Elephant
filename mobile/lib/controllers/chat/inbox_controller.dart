import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import '../../core/message_envelope.dart';
import '../../core/message_payload.dart';
import '../../core/message_summary.dart';
import '../../models/chat_prefs.dart';
import '../../models/group.dart';
import '../../models/inbox_item.dart';
import '../../services/api_services.dart';
import '../../services/calls/call_log.dart';
import '../../services/chat_folders.dart';
import '../../services/db_services.dart';
import '../../services/ws_service.dart';

/// How [InboxController.deleteConversation] deletes a chat.
enum ChatDeletion { forMe, forEveryone, wholeGroup }

class InboxController extends ChangeNotifier {
  final ApiService _api = ApiService();
  List<InboxItem> inbox = [];
  bool isLoading = false;
  bool hasLoadedOnce = false;

  /// Why the last load failed, shown instead of an empty inbox.
  String? loadError;

  List<InboxItem> get groups => inbox.where((item) => item.isGroup).toList();

  /// Chats with unread messages, for the badge. Archived and muted chats
  /// don't count: they asked not to be noisy.
  int get unreadChats => inbox.where((item) {
    final prefs = prefsOf(item.id);
    return item.unreadCount > 0 &&
        !item.isRequest &&
        !prefs.archived &&
        !prefs.isMuted();
  }).length;

  /// The message requests, newest first: first messages from people the
  /// person hasn't chatted with. They are kept out of the chat list.
  List<InboxItem> get requests =>
      inbox.where((item) => item.isRequest).toList();

  /// Whether [chatId] is a message request that hasn't been accepted.
  bool isRequest(String chatId) =>
      inbox.any((item) => item.id == chatId && item.isRequest);

  // --- Pinned, archived and muted chats ---

  Map<String, ChatPrefs> _prefs = {};

  // Groups with an unread message that mentions the person (lower-case
  // IDs). Kept while the app runs.
  final Set<String> _mentioned = {};
  bool _prefsLoaded = false;

  /// Whether a new message brings an archived chat back to the chat list.
  bool unarchiveOnMessage = false;

  static const _unarchiveKey = 'unarchive_on_message';

  static String _key(String chatId) => chatId.toLowerCase();

  /// Whether an unread message in [chatId] mentions the person.
  bool isMentioned(String chatId) => _mentioned.contains(_key(chatId));

  ChatPrefs prefsOf(String chatId) => _prefs[_key(chatId)] ?? ChatPrefs.none;

  /// The chats to show, pinned ones first (each group in the order of the
  /// list), without the archived ones.
  List<InboxItem> get chats =>
      _arranged(inbox.where((item) => !item.isRequest));

  /// Like [chats], for the Groups tab.
  List<InboxItem> get shownGroups => _arranged(groups);

  List<InboxItem> get archivedChats => inbox
      .where((item) => !item.isRequest && prefsOf(item.id).archived)
      .toList();

  List<InboxItem> _arranged(Iterable<InboxItem> items) {
    final shown = items.where((item) => !prefsOf(item.id).archived).toList();
    return [
      ...shown.where((item) => prefsOf(item.id).isPinned),
      ...shown.where((item) => !prefsOf(item.id).isPinned),
    ];
  }

  Future<void>? _prefsLoading;

  void _ensurePrefs() {
    if (_prefsLoaded) return;
    _prefsLoading ??= loadPrefs().whenComplete(() => _prefsLoading = null);
  }

  Future<void> loadPrefs() async {
    try {
      final stored = await DatabaseHelper.instance.loadChatPrefs();
      _prefs = {for (final e in stored.entries) _key(e.key): e.value};
      _prefsLoaded = true;
      unarchiveOnMessage =
          (await SharedPreferences.getInstance()).getBool(_unarchiveKey) ??
          false;
      notifyListeners();
    } catch (e) {
      debugPrint("Couldn't load chat settings: $e");
    }
  }

  Future<void> setUnarchiveOnMessage(bool on) async {
    unarchiveOnMessage = on;
    notifyListeners();
    try {
      await (await SharedPreferences.getInstance()).setBool(_unarchiveKey, on);
    } catch (e) {
      debugPrint("Couldn't save the archive setting: $e");
    }
  }

  /// Pins or unpins a chat. At most [ChatPrefs.maxPinned] can be pinned:
  /// returns a message to show if there's no room.
  Future<String?> setPinned(String chatId, bool pinned) async {
    final current = prefsOf(chatId);
    if (pinned) {
      final others = _prefs.entries.where(
        (e) => e.key != _key(chatId) && e.value.isPinned,
      );
      if (others.length >= ChatPrefs.maxPinned) {
        return 'You can pin up to ${ChatPrefs.maxPinned} chats. Unpin one first.';
      }
      await _setPrefs(chatId, current.copyWith(pinnedAt: DateTime.now()));
    } else {
      await _setPrefs(chatId, current.copyWith(clearPinned: true));
    }
    return null;
  }

  /// Moves a chat to or from Archived. Archiving also unpins it.
  Future<void> setArchived(String chatId, bool archived) {
    final current = prefsOf(chatId);
    return _setPrefs(
      chatId,
      archived
          ? current.copyWith(archived: true, clearPinned: true)
          : current.copyWith(archived: false),
    );
  }

  /// Mutes a chat for [duration], or always when it's null.
  Future<void> mute(String chatId, {Duration? duration}) => _setPrefs(
    chatId,
    prefsOf(chatId).copyWith(
      mutedUntil: duration == null
          ? ChatPrefs.forever
          : DateTime.now().add(duration),
    ),
  );

  Future<void> unmute(String chatId) =>
      _setPrefs(chatId, prefsOf(chatId).copyWith(clearMuted: true));

  Future<void> _setPrefs(String chatId, ChatPrefs next) async {
    if (next.isDefault) {
      _prefs.remove(_key(chatId));
    } else {
      _prefs[_key(chatId)] = next;
    }
    notifyListeners();
    try {
      await DatabaseHelper.instance.saveChatPrefs(chatId, next);
    } catch (e) {
      debugPrint("Couldn't save chat settings: $e");
    }
  }

  void clearInbox() {
    _prefs = {};
    _prefsLoaded = false;
    inbox = [];
    hasLoadedOnce = false;
    loadError = null;
    notifyListeners();
  }

  Future<void> loadInbox({
    bool isOffline = false,
    String? currentChatId,
  }) async {
    // Pinned, archived and muted chats arrive a moment later and re-arrange
    // the list, so the chats themselves aren't kept waiting for them.
    _ensurePrefs();
    try {
      final db = await DatabaseHelper.instance.database;
      final localData = await db.query('inbox', orderBy: 'timestamp DESC');
      if (localData.isNotEmpty && inbox.isEmpty) {
        inbox = localData.map(InboxItem.fromMap).toList();
        notifyListeners();
      }
    } catch (e) {
      debugPrint("Failed to load local inbox cache: $e");
      loadError = "Couldn't open your saved conversations.";
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
        if (json['last_message_deleted'] == true) {
          preview = 'This message was deleted';
        } else if (preview.isEmpty) {
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
      loadError = null;
      await _replaceInboxInDb(inbox);

      for (final chat in chatsToCatchUp) {
        if (chat.id != currentChatId && chat.lastMessage.isNotEmpty) {
          unawaited(_backgroundSyncChatHistoryToDb(chat.id, chat.isGroup));
        }
      }
    } catch (e) {
      debugPrint("Inbox fetch failed: $e");
      loadError = ApiService.errorMessage(
        e,
        fallback: "Couldn't load your conversations.",
      );
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
          AND content NOT LIKE ? AND deleted_at IS NULL
        GROUP BY chat_id
      ) l ON l.chat_id = m.chat_id AND l.latest = m.created_at
    ''',
      [
        '${MessageEnvelope.lockedPrefix}%',
        // Actions (reactions, votes, pins) are never a chat's last message.
        '%${MessagePayload.actionMarker}%',
      ],
    );
    return {
      for (final row in rows)
        row['chat_id'].toString(): summarizeContent(row['content'].toString()),
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
    bool mentionsMe = false,
  }) {
    final int index = inbox.indexWhere((item) => item.id == chatId);
    if (index == -1) {
      unawaited(loadInbox());
      return;
    }

    // A new message brings an archived chat back, if that's what's wanted.
    if (incrementUnread && unarchiveOnMessage && prefsOf(chatId).archived) {
      unawaited(setArchived(chatId, false));
    }

    final item = inbox.removeAt(index);
    item.lastMessage = lastMessage;
    item.timestamp = timestamp;
    item.lastMessageSender = senderId;
    item.lastMessageSyncStatus = syncStatus;
    item.lastMessageIsRead = isRead;
    if (incrementUnread) item.unreadCount += 1;
    if (incrementUnread && mentionsMe) _mentioned.add(_key(chatId));
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
    if (_mentioned.remove(_key(chatId))) notifyListeners();
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
    final unread = inbox
        .where((item) => item.unreadCount > 0 && !item.isRequest)
        .toList();
    await Future.wait(unread.map(markReadFor));
  }

  /// Shows an edited message's new text as the chat's preview, if it is the
  /// newest message in the chat. Earlier messages aren't shown in the inbox.
  Future<void> updatePreviewForEdit(
    String chatId,
    String messageId,
    String text,
  ) async {
    final index = inbox.indexWhere(
      (item) => item.id.toLowerCase() == chatId.toLowerCase(),
    );
    if (index == -1) return;

    try {
      final db = await DatabaseHelper.instance.database;
      final newest = await db.query(
        'messages',
        columns: ['id'],
        where: 'chat_id = ? COLLATE NOCASE',
        whereArgs: [chatId],
        orderBy: 'created_at DESC',
        limit: 1,
      );
      if (newest.isEmpty ||
          (newest.first['id'] as String).toLowerCase() !=
              messageId.toLowerCase()) {
        return;
      }
    } catch (e) {
      debugPrint("Couldn't tell whether the edited message is the newest: $e");
      return;
    }

    final stillThere = inbox.indexWhere(
      (item) => item.id.toLowerCase() == chatId.toLowerCase(),
    );
    if (stillThere == -1) return;
    inbox[stillThere] = inbox[stillThere].copyWith(
      lastMessage: MessageEnvelope.isUnreadable(text)
          ? '🔒 Encrypted message'
          : text,
    );
    notifyListeners();
    _saveItem(inbox[stillThere]);
  }

  void renameLocal(String chatId, String newTitle) {
    final index = inbox.indexWhere((item) => item.id == chatId);
    if (index == -1) return;
    inbox[index] = inbox[index].copyWith(title: newTitle);
    notifyListeners();
    _saveItem(inbox[index]);
  }

  /// Deletes a conversation through the server, then locally.
  ///
  /// - [ChatDeletion.forMe]: hides the chat's messages from you (a group stays
  ///   joined). It comes back when a new message arrives.
  /// - [ChatDeletion.forEveryone] (direct chats): also deletes every message
  ///   you sent in it, for both people. Theirs are never deleted.
  /// - [ChatDeletion.wholeGroup] (group admins): deletes the group.
  ///
  /// Returns an error message, or null on success.
  Future<String?> deleteConversation(
    String chatId, {
    required bool isGroup,
    required ChatDeletion how,
  }) async {
    try {
      if (how == ChatDeletion.wholeGroup) {
        await _api.deleteGroup(chatId);
        await removeChat(chatId);
        return null;
      }
      final res = isGroup
          ? await _api.clearGroupHistory(chatId)
          : await _api.deleteConversation(
              chatId,
              forEveryone: how == ChatDeletion.forEveryone,
            );
      final clearedAt =
          DateTime.tryParse(ApiService.dataMap(res.data)['cleared_at'] ?? '') ??
          DateTime.now();
      inbox.removeWhere((item) => item.id == chatId);
      notifyListeners();
      await DatabaseHelper.instance.deleteMessagesUpTo(chatId, clearedAt);
      final db = await DatabaseHelper.instance.database;
      await db.delete('inbox', where: 'id = ?', whereArgs: [chatId]);
      return null;
    } catch (e) {
      return ApiService.errorMessage(e, fallback: "Couldn't delete the chat.");
    }
  }

  /// Replaces the call that accepts a request, in tests.
  @visibleForTesting
  Future<Object?> Function(String userId)? requestAccepter;

  /// Accepts the request from [chatId]. Returns an error to show, or null.
  Future<String?> acceptRequest(String chatId) async {
    try {
      await (requestAccepter ?? _api.acceptMessageRequest)(chatId);
    } catch (e) {
      return ApiService.errorMessage(
        e,
        fallback: "Couldn't accept the request.",
      );
    }
    final index = inbox.indexWhere((item) => item.id == chatId);
    if (index != -1) {
      inbox[index].isRequest = false;
      notifyListeners();
      _saveItem(inbox[index]);
    }
    return null;
  }

  Future<void> removeChat(String chatId) async {
    inbox.removeWhere((item) => item.id == chatId);
    _prefs.remove(_key(chatId));
    notifyListeners();
    CallLog.instance.forget(chatId);
    ChatFolders.instance.forgetChat(chatId);
    await DatabaseHelper.instance.deleteChat(chatId);
  }

  void _saveItem(InboxItem item) {
    DatabaseHelper.instance.database
        .then((db) async {
          await db.insert(
            'inbox',
            item.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        })
        .catchError((Object e) {
          debugPrint("Couldn't save a chat list entry: $e");
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
