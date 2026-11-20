import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import '../core/message_envelope.dart';
import '../models/chat_prefs.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;
  static Future<Database>? _opening;
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  static const String _dbName = 'secure_chat.db';

  DatabaseHelper._init();

  /// Opens the database once. Concurrent first callers share the same
  /// future, so the encryption key is only ever generated once.
  Future<Database> get database async {
    final db = _database;
    if (db != null) return db;
    final opening = _opening ??= _initDB(_dbName);
    try {
      return _database = await opening;
    } finally {
      _opening = null;
    }
  }

  Future<String> _getEncryptionKey() async {
    const keyName = 'db_encryption_key';
    String? key;

    try {
      key = await _secureStorage.read(key: keyName);
    } on PlatformException catch (e) {
      if (e.message?.contains('BAD_DECRYPT') == true ||
          e.code == 'Exception encountered') {
        debugPrint(
          'CRITICAL: Keystore corrupted. Wiping secure storage and resetting DB.',
        );

        await _secureStorage.deleteAll();

        final dbPath = join(await getDatabasesPath(), _dbName);
        await deleteDatabase(dbPath);

        key = null;
      } else {
        rethrow;
      }
    }

    if (key == null) {
      final random = Random.secure();
      final secureBytes = List<int>.generate(32, (_) => random.nextInt(256));
      final secureKey = base64Url.encode(secureBytes);

      await _secureStorage.write(key: keyName, value: secureKey);
      key = secureKey;
    }

    return key;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);
    final password = await _getEncryptionKey();

    try {
      return await _open(path, password);
    } on DatabaseException catch (e) {
      if (!await databaseExists(path)) rethrow;
      // The file was encrypted with a key we no longer have. It only holds a
      // cache and this device's Signal keys, which are regenerated and
      // republished on the next sign-in, so start over instead of failing on
      // every launch.
      debugPrint('Local database unreadable, recreating it: $e');
      await deleteDatabase(path);
      return await _open(path, password);
    }
  }

  Future<Database> _open(String path, String password) {
    return openDatabase(
      path,
      version: 9,
      password: password,
      onCreate: _createDB,
      onUpgrade: _upgradeDB,
    );
  }

  Future _upgradeDB(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE messages ADD COLUMN edited_at INTEGER');
    }
    if (oldVersion < 3) await _createCallLog(db);
    if (oldVersion < 4) {
      await db.execute('ALTER TABLE messages ADD COLUMN deleted_at INTEGER');
    }
    if (oldVersion < 5) {
      await db.execute('ALTER TABLE messages ADD COLUMN delivered_at INTEGER');
    }
    if (oldVersion < 6) await _createChatPrefs(db);
    if (oldVersion < 7) await _createStarred(db);
    if (oldVersion < 8) await _createDrafts(db);
    if (oldVersion < 9) await _createChatFolders(db);
  }

  /// Messages the person starred, to find them again. Only on this phone.
  Future<void> _createStarred(Database db) async {
    await db.execute('''
      CREATE TABLE starred_messages (
        message_id TEXT PRIMARY KEY COLLATE NOCASE,
        chat_id TEXT NOT NULL,
        starred_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX starred_messages_chat ON starred_messages (chat_id)',
    );
  }

  /// Folders the person made to sort chats. Only on this phone.
  Future<void> _createChatFolders(Database db) async {
    await db.execute('''
      CREATE TABLE chat_folders (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        chat_ids TEXT NOT NULL,
        position INTEGER NOT NULL
      )
    ''');
  }

  /// What was typed in a chat but not sent. Only on this phone.
  Future<void> _createDrafts(Database db) async {
    await db.execute('''
      CREATE TABLE chat_drafts (
        chat_id TEXT PRIMARY KEY,
        text TEXT NOT NULL,
        reply_to_id TEXT,
        updated_at INTEGER NOT NULL
      )
    ''');
  }

  /// How each chat is arranged on this phone (pinned, archived, muted).
  Future<void> _createChatPrefs(Database db) async {
    await db.execute('''
      CREATE TABLE chat_prefs (
        chat_id TEXT PRIMARY KEY,
        pinned_at INTEGER,
        archived INTEGER NOT NULL DEFAULT 0,
        muted_until INTEGER
      )
    ''');
  }

  /// Calls made and received, shown in the chat. Only kept on this device.
  Future<void> _createCallLog(Database db) async {
    await db.execute('''
      CREATE TABLE call_log (
        id TEXT PRIMARY KEY,
        chat_id TEXT NOT NULL,
        outgoing INTEGER NOT NULL,
        outcome TEXT NOT NULL,
        started_at INTEGER NOT NULL,
        duration_seconds INTEGER NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX call_log_chat ON call_log (chat_id)');
  }

  Future _createDB(Database db, int version) async {
    await _createCallLog(db);
    await _createChatPrefs(db);
    await _createStarred(db);
    await _createDrafts(db);
    await _createChatFolders(db);
    await db.execute('''
      CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        chat_id TEXT NOT NULL,
        sender_id TEXT NOT NULL,
        content TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        is_read INTEGER NOT NULL,
        reply_to_id TEXT,
        sync_status TEXT NOT NULL, -- 'synced' or 'pending'
        edited_at INTEGER,
        deleted_at INTEGER, -- deleted for everyone
        delivered_at INTEGER -- reached the recipient's phone
      )
    ''');

    await db.execute('''
      CREATE TABLE signal_sender_keys (
        sender_key_name TEXT PRIMARY KEY,
        record TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE action_queue (
        id TEXT PRIMARY KEY,
        action_type TEXT NOT NULL, -- e.g., 'send_message', 'read_receipt'
        payload TEXT NOT NULL,     -- JSON string of the data
        created_at INTEGER NOT NULL,
        retry_count INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE inbox (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        username TEXT,
        last_message TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        is_group INTEGER NOT NULL,
        is_read INTEGER NOT NULL,
        unread_count INTEGER DEFAULT 0,
        last_message_sender TEXT,
        last_message_sync_status TEXT, -- MUST BE ADDED
        last_message_is_read INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE group_members (
        group_id TEXT NOT NULL,
        user_id TEXT NOT NULL,
        display_name TEXT,
        PRIMARY KEY (group_id, user_id)
      )
    ''');

    await db.execute('''
      CREATE TABLE signal_local_keys (
        id INTEGER PRIMARY KEY DEFAULT 1,
        registration_id INTEGER NOT NULL,
        identity_key_pair TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE signal_identities (
        address TEXT PRIMARY KEY,
        identity_key TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE signal_sessions (
        address TEXT PRIMARY KEY,
        record TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE signal_prekeys (
        key_id INTEGER PRIMARY KEY,
        record TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE signal_signed_prekeys (
        key_id INTEGER PRIMARY KEY,
        record TEXT NOT NULL
      )
    ''');
  }

  /// Inserts or replaces a message, never overwriting cached plaintext with
  /// ciphertext or a "can't decrypt" placeholder.
  Future<int> insertMessage(Map<String, dynamic> row) async {
    final db = await instance.database;

    final newContent = row['content']?.toString();
    if (newContent != null && MessageEnvelope.isUnreadable(newContent)) {
      final existing = await db.query(
        'messages',
        columns: ['content'],
        where: 'id = ?',
        whereArgs: [row['id']],
      );
      if (existing.isNotEmpty) {
        final oldContent = existing.first['content'].toString();
        if (!MessageEnvelope.isUnreadable(oldContent)) {
          row['content'] = oldContent;
        }
      }
    }

    return await db.insert(
      'messages',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Removes a conversation and its cached messages, e.g. after leaving a group.
  Future<void> deleteChat(String chatId) async {
    final db = await instance.database;
    await db.delete('messages', where: 'chat_id = ?', whereArgs: [chatId]);
    await db.delete('call_log', where: 'chat_id = ?', whereArgs: [chatId]);
    await db.delete('chat_prefs', where: 'chat_id = ?', whereArgs: [chatId]);
    await db.delete(
      'chat_drafts',
      where: 'chat_id = ?',
      whereArgs: [chatId.toLowerCase()],
    );
    await db.delete(
      'starred_messages',
      where: 'chat_id = ?',
      whereArgs: [chatId],
    );
    await db.delete('inbox', where: 'id = ?', whereArgs: [chatId]);
    await db.delete(
      'group_members',
      where: 'group_id = ?',
      whereArgs: [chatId],
    );
  }

  /// The folders, in the order they were made.
  Future<List<Map<String, Object?>>> chatFolders() async {
    final db = await instance.database;
    return db.query('chat_folders', orderBy: 'position');
  }

  Future<void> saveChatFolder(
    String id,
    String name,
    Set<String> chatIds,
    int position,
  ) async {
    final db = await instance.database;
    await db.insert('chat_folders', {
      'id': id,
      'name': name,
      'chat_ids': jsonEncode(chatIds.toList()),
      'position': position,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteChatFolder(String id) async {
    final db = await instance.database;
    await db.delete('chat_folders', where: 'id = ?', whereArgs: [id]);
  }

  static Set<String> decodeChatIds(String json) {
    try {
      return {for (final id in jsonDecode(json) as List) id as String};
    } catch (_) {
      return {};
    }
  }

  /// Every saved draft.
  Future<List<Map<String, Object?>>> drafts() async {
    final db = await instance.database;
    return db.query('chat_drafts');
  }

  Future<void> saveDraft(String chatId, String text, String? replyToId) async {
    final db = await instance.database;
    await db.insert('chat_drafts', {
      'chat_id': chatId,
      'text': text,
      'reply_to_id': replyToId,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteDraft(String chatId) async {
    final db = await instance.database;
    await db.delete('chat_drafts', where: 'chat_id = ?', whereArgs: [chatId]);
  }

  /// The IDs of every starred message.
  Future<Set<String>> starredMessageIds() async {
    final db = await instance.database;
    final rows = await db.query('starred_messages', columns: ['message_id']);
    return {for (final row in rows) (row['message_id'] as String)};
  }

  /// Stars or unstars a message of [chatId].
  Future<void> setMessageStarred(
    String chatId,
    String messageId,
    bool starred,
  ) async {
    final db = await instance.database;
    if (!starred) {
      await db.delete(
        'starred_messages',
        where: 'message_id = ?',
        whereArgs: [messageId],
      );
      return;
    }
    await db.insert('starred_messages', {
      'message_id': messageId,
      'chat_id': chatId,
      'starred_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Starred messages that are still in the cache, newest star first, with
  /// when each was starred. Only [chatId]'s if given.
  Future<List<({Map<String, dynamic> message, DateTime starredAt})>>
  starredMessages({String? chatId}) async {
    final db = await instance.database;
    final rows = await db.rawQuery(
      '''
      SELECT m.*, s.starred_at AS starred_at
      FROM starred_messages s
      JOIN messages m ON m.id = s.message_id COLLATE NOCASE
      ${chatId == null ? '' : 'WHERE s.chat_id = ?'}
      ORDER BY s.starred_at DESC
    ''',
      [?chatId],
    );
    return [
      for (final row in rows)
        (
          message: Map<String, dynamic>.from(row),
          starredAt: DateTime.fromMillisecondsSinceEpoch(
            row['starred_at'] as int,
          ),
        ),
    ];
  }

  /// Every chat's pinned, archived and muted settings, by chat ID.
  Future<Map<String, ChatPrefs>> loadChatPrefs() async {
    final db = await instance.database;
    final rows = await db.query('chat_prefs');
    return {
      for (final row in rows) row['chat_id'] as String: ChatPrefs.fromRow(row),
    };
  }

  /// Stores [prefs] for a chat, or forgets the chat if they're all default.
  Future<void> saveChatPrefs(String chatId, ChatPrefs prefs) async {
    final db = await instance.database;
    if (prefs.isDefault) {
      await db.delete('chat_prefs', where: 'chat_id = ?', whereArgs: [chatId]);
      return;
    }
    await db.insert(
      'chat_prefs',
      prefs.toRow(chatId),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Records when messages we sent reached the other person's phone.
  Future<void> markMessagesDelivered(List<String> ids, DateTime at) async {
    if (ids.isEmpty) return;
    final db = await instance.database;
    await db.update(
      'messages',
      {'delivered_at': at.millisecondsSinceEpoch},
      where:
          'delivered_at IS NULL AND id COLLATE NOCASE IN (${List.filled(ids.length, '?').join(',')})',
      whereArgs: ids,
    );
  }

  /// Keeps a message as a tombstone: deleted for everyone, content gone.
  Future<void> markMessageDeleted(String messageId, DateTime at) async {
    final db = await instance.database;
    await db.update(
      'messages',
      {'content': '', 'deleted_at': at.millisecondsSinceEpoch},
      where: 'id = ? COLLATE NOCASE',
      whereArgs: [messageId],
    );
  }

  /// Removes one cached message (deleted for me).
  Future<void> deleteMessageById(String messageId) async {
    final db = await instance.database;
    await db.delete(
      'messages',
      where: 'id = ? COLLATE NOCASE',
      whereArgs: [messageId],
    );
  }

  /// Removes a chat's cached messages created at or before [upTo], or only
  /// those [fromSender] sent. Messages that arrived later are kept.
  Future<void> deleteMessagesUpTo(
    String chatId,
    DateTime upTo, {
    String? fromSender,
  }) async {
    final db = await instance.database;
    await db.delete(
      'messages',
      where:
          'chat_id = ? AND created_at <= ?'
          '${fromSender == null ? '' : ' AND sender_id = ? COLLATE NOCASE'}',
      whereArgs: [chatId, upTo.millisecondsSinceEpoch, ?fromSender],
    );
  }

  /// Deletes every cached conversation, message and queued send.
  Future<void> wipeChatData() async {
    final db = await instance.database;
    await db.delete('messages');
    await db.delete('call_log');
    await db.delete('chat_prefs');
    await db.delete('starred_messages');
    await db.delete('chat_drafts');
    await db.delete('chat_folders');
    await db.delete('inbox');
    await db.delete('action_queue');
    await db.delete('group_members');
  }

  /// Deletes every local Signal key, session and identity.
  Future<void> wipeSignalState() async {
    final db = await instance.database;
    await db.delete('signal_local_keys');
    await db.delete('signal_identities');
    await db.delete('signal_sessions');
    await db.delete('signal_prekeys');
    await db.delete('signal_signed_prekeys');
    await db.delete('signal_sender_keys');
  }

  Future<void> queueAction(
    String id,
    String type,
    Map<String, dynamic> payload,
  ) async {
    final db = await instance.database;
    await db.insert('action_queue', {
      'id': id,
      'action_type': type,
      'payload': jsonEncode(payload),
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }
}
