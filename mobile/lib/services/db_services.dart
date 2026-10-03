import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import '../core/message_envelope.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  static const String _dbName = 'secure_chat.db';

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB(_dbName);
    return _database!;
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

    return await openDatabase(
      path,
      version: 2,
      password: password,
      onCreate: _createDB,
      onUpgrade: _upgradeDB,
    );
  }

  Future _upgradeDB(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE messages ADD COLUMN edited_at INTEGER');
    }
  }

  Future _createDB(Database db, int version) async {
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
        edited_at INTEGER
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
    await db.delete('inbox', where: 'id = ?', whereArgs: [chatId]);
    await db.delete(
      'group_members',
      where: 'group_id = ?',
      whereArgs: [chatId],
    );
  }

  /// Deletes every cached conversation, message and queued send.
  Future<void> wipeChatData() async {
    final db = await instance.database;
    await db.delete('messages');
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
