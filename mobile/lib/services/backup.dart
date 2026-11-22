import 'dart:typed_data';

import 'package:sqflite_sqlcipher/sqflite.dart';

import '../core/backup_codec.dart';
import 'db_services.dart';

/// The tables a backup holds: the chats and what goes with them on this phone.
/// Not the encryption keys (a restored phone starts with new ones, so it never
/// reuses a session another phone is still using) nor the queue of unsent
/// messages, and not what the server can say again, such as group members.
const backupTables = [
  'messages',
  'inbox',
  'call_log',
  'chat_prefs',
  'starred_messages',
  'chat_folders',
  'broadcast_lists',
  'contact_nicknames',
];

typedef BackupTables = Map<String, List<Map<String, Object?>>>;

/// Where the chat data is read from and put back. The app uses its encrypted
/// database; tests use memory.
abstract class BackupStore {
  Future<BackupTables> dump();

  /// Replaces everything in [backupTables] with [tables], all or nothing.
  Future<void> replaceAll(BackupTables tables);
}

class DatabaseBackupStore implements BackupStore {
  @override
  Future<BackupTables> dump() async {
    final db = await DatabaseHelper.instance.database;
    final out = <String, List<Map<String, Object?>>>{};
    for (final table in backupTables) {
      out[table] = await db.query(
        table,
        // A message that never left this phone has nothing to send it again.
        where: table == 'messages' ? "sync_status = 'synced'" : null,
      );
    }
    return out;
  }

  @override
  Future<void> replaceAll(BackupTables tables) async {
    final db = await DatabaseHelper.instance.database;
    await db.transaction((txn) async {
      for (final table in backupTables) {
        await txn.delete(table);
        final batch = txn.batch();
        for (final row in tables[table] ?? const []) {
          batch.insert(
            table,
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await batch.commit(noResult: true);
      }
    });
  }
}

/// What a backup held, for telling the person.
class BackupSummary {
  final DateTime createdAt;
  final int messages;
  final int chats;

  const BackupSummary({
    required this.createdAt,
    required this.messages,
    required this.chats,
  });
}

/// Makes encrypted backups of the chats on this phone, and puts one back.
class BackupService {
  BackupService({BackupStore? store, this.cost = const BackupCost()})
    : _store = store ?? DatabaseBackupStore();

  final BackupStore _store;
  final BackupCost cost;

  static const app = 'elephant';
  static const format = 1;

  /// A backup of the chats, encrypted with [passphrase], for [userId].
  Future<Uint8List> create({
    required String userId,
    required String passphrase,
    DateTime? now,
  }) async {
    final tables = await _store.dump();
    return BackupCodec.seal(
      {
        'app': app,
        'format': format,
        'user_id': userId.toLowerCase(),
        'created_at': (now ?? DateTime.now()).toUtc().toIso8601String(),
        'tables': tables,
      },
      passphrase,
      cost: cost,
    );
  }

  /// Opens [file] and, if it is a backup of [userId]'s chats, replaces the
  /// chats on this phone with it. Nothing changes if anything is wrong with
  /// the file, the passphrase or the account.
  Future<BackupSummary> restore(
    Uint8List file,
    String passphrase, {
    required String userId,
  }) async {
    final snapshot = await BackupCodec.open(file, passphrase);
    final tables = _tablesOf(snapshot);
    if (snapshot['user_id'] != userId.toLowerCase()) {
      throw const BackupException(BackupProblem.otherAccount);
    }
    await _store.replaceAll(tables);
    return BackupSummary(
      createdAt:
          DateTime.tryParse('${snapshot['created_at']}')?.toLocal() ??
          DateTime.now(),
      messages: tables['messages']?.length ?? 0,
      chats: tables['inbox']?.length ?? 0,
    );
  }

  /// The rows of a snapshot, checked to be what a backup holds.
  BackupTables _tablesOf(Map<String, Object?> snapshot) {
    const bad = BackupException(BackupProblem.notABackup);
    if (snapshot['app'] != app || snapshot['user_id'] is! String) throw bad;
    final version = snapshot['format'];
    if (version is! int) throw bad;
    if (version > format) throw const BackupException(BackupProblem.tooNew);
    final raw = snapshot['tables'];
    if (raw is! Map) throw bad;

    final out = <String, List<Map<String, Object?>>>{};
    for (final table in backupTables) {
      final rows = raw[table];
      if (rows == null) continue;
      if (rows is! List) throw bad;
      out[table] = [
        for (final row in rows)
          if (row is Map && row.values.every(_isScalar))
            Map<String, Object?>.from(row)
          else
            throw bad,
      ];
    }
    return out;
  }

  static bool _isScalar(Object? v) => v == null || v is num || v is String;
}
