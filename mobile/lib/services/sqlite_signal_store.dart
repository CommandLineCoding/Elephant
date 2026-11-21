import 'dart:convert';
import 'dart:typed_data';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import 'db_services.dart';

class SQLiteSignalStore implements SignalProtocolStore, SenderKeyStore {
  String _toB64(Uint8List bytes) => base64Encode(bytes);

  Uint8List _fromB64(String b64) => base64Decode(b64);

  Future<void> storeLocalData(
    IdentityKeyPair keyPair,
    int registrationId,
  ) async {
    final db = await DatabaseHelper.instance.database;
    await db.insert('signal_local_keys', {
      'id': 1,
      'registration_id': registrationId,
      'identity_key_pair': _toB64(keyPair.serialize()),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<IdentityKeyPair> getIdentityKeyPair() async {
    final db = await DatabaseHelper.instance.database;
    final res = await db.query('signal_local_keys', where: 'id = 1');
    if (res.isEmpty) throw Exception("Local Identity Key not generated yet.");
    return IdentityKeyPair.fromSerialized(
      _fromB64(res.first['identity_key_pair'] as String),
    );
  }

  @override
  Future<int> getLocalRegistrationId() async {
    final db = await DatabaseHelper.instance.database;
    final res = await db.query('signal_local_keys', where: 'id = 1');
    if (res.isEmpty) throw Exception("Registration ID not generated yet.");
    return res.first['registration_id'] as int;
  }

  @override
  Future<bool> saveIdentity(
    SignalProtocolAddress address,
    IdentityKey? identityKey,
  ) async {
    if (identityKey == null) return false;
    final db = await DatabaseHelper.instance.database;
    final existing = await getIdentity(address);

    if (existing != null && existing != identityKey) {
      await db.update(
        'signal_identities',
        {'identity_key': _toB64(identityKey.serialize())},
        where: 'address = ?',
        whereArgs: [address.getName()],
      );
      return true;
    }

    await db.insert('signal_identities', {
      'address': address.getName(),
      'identity_key': _toB64(identityKey.serialize()),
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    return false;
  }

  @override
  Future<IdentityKey?> getIdentity(SignalProtocolAddress address) async {
    final db = await DatabaseHelper.instance.database;
    final res = await db.query(
      'signal_identities',
      where: 'address = ?',
      whereArgs: [address.getName()],
    );
    if (res.isEmpty) return null;

    return IdentityKey.fromBytes(
      _fromB64(res.first['identity_key'] as String),
      0,
    );
  }

  @override
  Future<bool> isTrustedIdentity(
    SignalProtocolAddress address,
    IdentityKey? identityKey,
    Direction direction,
  ) async {
    if (identityKey == null) return false;
    final trusted = await getIdentity(address);
    return trusted == null || trusted == identityKey;
  }

  @override
  Future<PreKeyRecord> loadPreKey(int preKeyId) async {
    final db = await DatabaseHelper.instance.database;
    final res = await db.query(
      'signal_prekeys',
      where: 'key_id = ?',
      whereArgs: [preKeyId],
    );
    if (res.isEmpty) throw InvalidKeyIdException("No prekey found");
    return PreKeyRecord.fromBuffer(_fromB64(res.first['record'] as String));
  }

  @override
  Future<void> storePreKey(int preKeyId, PreKeyRecord record) async {
    final db = await DatabaseHelper.instance.database;
    await db.insert('signal_prekeys', {
      'key_id': preKeyId,
      'record': _toB64(record.serialize()),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<bool> containsPreKey(int preKeyId) async {
    final db = await DatabaseHelper.instance.database;
    final res = await db.query(
      'signal_prekeys',
      where: 'key_id = ?',
      whereArgs: [preKeyId],
    );
    return res.isNotEmpty;
  }

  @override
  Future<void> removePreKey(int preKeyId) async {
    final db = await DatabaseHelper.instance.database;
    await db.delete(
      'signal_prekeys',
      where: 'key_id = ?',
      whereArgs: [preKeyId],
    );
  }

  @override
  Future<SignedPreKeyRecord> loadSignedPreKey(int signedPreKeyId) async {
    final db = await DatabaseHelper.instance.database;
    final res = await db.query(
      'signal_signed_prekeys',
      where: 'key_id = ?',
      whereArgs: [signedPreKeyId],
    );
    if (res.isEmpty) throw InvalidKeyIdException("No signed prekey found");

    return SignedPreKeyRecord.fromSerialized(
      _fromB64(res.first['record'] as String),
    );
  }

  @override
  Future<List<SignedPreKeyRecord>> loadSignedPreKeys() async {
    final db = await DatabaseHelper.instance.database;
    final res = await db.query('signal_signed_prekeys');
    return res
        .map(
          (row) => SignedPreKeyRecord.fromSerialized(
            _fromB64(row['record'] as String),
          ),
        )
        .toList();
  }

  @override
  Future<void> storeSignedPreKey(
    int signedPreKeyId,
    SignedPreKeyRecord record,
  ) async {
    final db = await DatabaseHelper.instance.database;
    await db.insert('signal_signed_prekeys', {
      'key_id': signedPreKeyId,
      'record': _toB64(record.serialize()),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<bool> containsSignedPreKey(int signedPreKeyId) async {
    final db = await DatabaseHelper.instance.database;
    final res = await db.query(
      'signal_signed_prekeys',
      where: 'key_id = ?',
      whereArgs: [signedPreKeyId],
    );
    return res.isNotEmpty;
  }

  @override
  Future<void> removeSignedPreKey(int signedPreKeyId) async {
    final db = await DatabaseHelper.instance.database;
    await db.delete(
      'signal_signed_prekeys',
      where: 'key_id = ?',
      whereArgs: [signedPreKeyId],
    );
  }

  @override
  Future<SessionRecord> loadSession(SignalProtocolAddress address) async {
    final db = await DatabaseHelper.instance.database;
    final res = await db.query(
      'signal_sessions',
      where: 'address = ?',
      whereArgs: [address.getName()],
    );
    if (res.isEmpty) {
      return SessionRecord();
    }
    return SessionRecord.fromSerialized(
      _fromB64(res.first['record'] as String),
    );
  }

  @override
  Future<List<int>> getSubDeviceSessions(String name) async {
    return [1];
  }

  @override
  Future<void> storeSession(
    SignalProtocolAddress address,
    SessionRecord record,
  ) async {
    final db = await DatabaseHelper.instance.database;
    await db.insert('signal_sessions', {
      'address': address.getName(),
      'record': _toB64(record.serialize()),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<bool> containsSession(SignalProtocolAddress address) async {
    final db = await DatabaseHelper.instance.database;
    final res = await db.query(
      'signal_sessions',
      where: 'address = ?',
      whereArgs: [address.getName()],
    );
    return res.isNotEmpty;
  }

  @override
  Future<void> deleteSession(SignalProtocolAddress address) async {
    final db = await DatabaseHelper.instance.database;
    await db.delete(
      'signal_sessions',
      where: 'address = ?',
      whereArgs: [address.getName()],
    );
  }

  @override
  Future<void> deleteAllSessions(String name) async {
    final db = await DatabaseHelper.instance.database;
    await db.delete('signal_sessions', where: 'address = ?', whereArgs: [name]);
  }

  @override
  Future<void> storeSenderKey(
    SenderKeyName senderKeyName,
    SenderKeyRecord record,
  ) async {
    final db = await DatabaseHelper.instance.database;
    final keyNameStr =
        "${senderKeyName.groupId}::${senderKeyName.sender.getName()}";

    await db.insert('signal_sender_keys', {
      'sender_key_name': keyNameStr,
      'record': _toB64(record.serialize()),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<SenderKeyRecord> loadSenderKey(SenderKeyName senderKeyName) async {
    final db = await DatabaseHelper.instance.database;
    final keyNameStr =
        "${senderKeyName.groupId}::${senderKeyName.sender.getName()}";

    final res = await db.query(
      'signal_sender_keys',
      where: 'sender_key_name = ?',
      whereArgs: [keyNameStr],
    );

    if (res.isEmpty) {
      return SenderKeyRecord();
    }
    return SenderKeyRecord.fromSerialized(
      _fromB64(res.first['record'] as String),
    );
  }
}
