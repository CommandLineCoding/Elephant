import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobile/core/message_envelope.dart';
import 'package:mobile/services/sqlite_signal_store.dart';
import 'package:mobile/services/db_services.dart';
import 'api_services.dart';

/// Result of a contact-verification lookup.
class VerificationInfo {
  final String safetyNumber;
  final bool isVerified;

  const VerificationInfo({
    required this.safetyNumber,
    required this.isVerified,
  });
}

/// Client side of the Signal Protocol. The server (`/api/e2ee/*`) only stores
/// public keys; every private key stays in the local encrypted database.
class SignalService {
  static final SignalService _instance = SignalService._internal();
  factory SignalService() => _instance;

  final ApiService _api = ApiService();

  late SQLiteSignalStore _store;
  bool _isInitialized = false;

  /// Bundle fetches consume a one-time prekey on the server, so concurrent
  /// session setups for the same contact share one request.
  final Map<String, Future<bool>> _pendingSessions = {};

  static const String deviceId = 'main';
  static const int _initialPreKeyCount = 100;
  static const int _refillPreKeyCount = 50;
  static const int _signedPreKeyId = 0;
  static const String _nextPreKeyIdPref = 'signal_next_prekey_id';

  /// Signal state is a ratchet: every encrypt/decrypt mutates it, so all
  /// operations run one at a time.
  Future<void> _queue = Future.value();

  Future<T> _serial<T>(Future<T> Function() task) {
    final result = _queue.then((_) => task());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  SignalService._internal();

  Future<void> initStore() async {
    if (_isInitialized) return;
    _store = SQLiteSignalStore();
    _isInitialized = true;
  }

  SignalProtocolAddress _getAddress(String userId) =>
      SignalProtocolAddress(userId, 1);

  // --- Key lifecycle ---

  /// Makes sure this device has an identity and that the server holds its
  /// public keys, topping up one-time prekeys when the server reports < 10.
  Future<void> ensureKeysPublished() async {
    await initStore();
    try {
      final generated = await _ensureIdentity();
      final requiresRefill = await _upload(includeLocalPreKeys: generated);
      if (requiresRefill) {
        await _refillPreKeys();
      }
    } catch (e) {
      debugPrint("E2EE: failed to publish keys: $e");
    }
  }

  /// Generates a fresh identity if none exists. Returns true when it did.
  Future<bool> _ensureIdentity() async {
    final db = await DatabaseHelper.instance.database;
    final existingKeys = await db.query('signal_local_keys', where: 'id = 1');
    if (existingKeys.isNotEmpty) return false;

    debugPrint("E2EE: generating a new identity");
    final identityKeyPair = generateIdentityKeyPair();
    final registrationId = generateRegistrationId(false);
    await _store.storeLocalData(identityKeyPair, registrationId);

    final signedPreKey = generateSignedPreKey(identityKeyPair, _signedPreKeyId);
    await _store.storeSignedPreKey(signedPreKey.id, signedPreKey);

    for (final preKey in generatePreKeys(0, _initialPreKeyCount)) {
      await _store.storePreKey(preKey.id, preKey);
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_nextPreKeyIdPref, _initialPreKeyCount);
    return true;
  }

  /// Uploads identity and signed prekey. One-time prekeys are only sent when
  /// [includeLocalPreKeys] or [preKeys] is given, because the server appends
  /// them and re-sending would create duplicates.
  Future<bool> _upload({
    bool includeLocalPreKeys = false,
    List<PreKeyRecord>? preKeys,
  }) async {
    final identityKeyPair = await _store.getIdentityKeyPair();
    final signedPreKey = await _store.loadSignedPreKey(_signedPreKeyId);

    List<PreKeyRecord> oneTime = preKeys ?? [];
    if (includeLocalPreKeys) {
      final db = await DatabaseHelper.instance.database;
      final rows = await db.query('signal_prekeys');
      oneTime = rows
          .map(
            (row) =>
                PreKeyRecord.fromBuffer(base64Decode(row['record'] as String)),
          )
          .toList();
    }

    final res = await _api.uploadPrekeys({
      'device_id': deviceId,
      'identity_key': base64Encode(identityKeyPair.getPublicKey().serialize()),
      'signed_prekey': base64Encode(
        signedPreKey.getKeyPair().publicKey.serialize(),
      ),
      'signature': base64Encode(signedPreKey.signature),
      'one_time_prekeys': oneTime
          .map(
            (k) => {
              'id': k.id,
              'content': base64Encode(k.getKeyPair().publicKey.serialize()),
            },
          )
          .toList(),
    });

    return ApiService.dataMap(res.data)['requires_refill'] == true;
  }

  Future<void> _refillPreKeys() async {
    final prefs = await SharedPreferences.getInstance();
    int nextId = prefs.getInt(_nextPreKeyIdPref) ?? 0;

    // Installs from before the counter existed: start past every used id.
    if (nextId < _initialPreKeyCount) {
      final db = await DatabaseHelper.instance.database;
      final maxRow = await db.rawQuery(
        'SELECT MAX(key_id) AS max_id FROM signal_prekeys',
      );
      final maxLocal = (maxRow.first['max_id'] as int?) ?? 0;
      nextId = maxLocal + 1 > _initialPreKeyCount
          ? maxLocal + 1
          : _initialPreKeyCount;
    }

    final batch = generatePreKeys(nextId, _refillPreKeyCount);
    for (final preKey in batch) {
      await _store.storePreKey(preKey.id, preKey);
    }
    await prefs.setInt(_nextPreKeyIdPref, nextId + _refillPreKeyCount);
    await _upload(preKeys: batch);
    debugPrint("E2EE: uploaded ${batch.length} new one-time prekeys");
  }

  /// Wipes this account's keys on the server (password re-auth), then
  /// generates and publishes a fresh identity. Existing sessions end.
  Future<void> resetAllKeys(String password) async {
    await initStore();
    await _api.resetEncryptionKeys(password);
    await DatabaseHelper.instance.wipeSignalState();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_nextPreKeyIdPref);
    await ensureKeysPublished();
  }

  /// Deletes local keys, e.g. when a different account signs in on this device.
  Future<void> wipeLocalKeys() async {
    await DatabaseHelper.instance.wipeSignalState();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_nextPreKeyIdPref);
  }

  // --- Sessions ---

  Future<bool> establishSessionIfNeeded(String remoteUserId) {
    return _pendingSessions[remoteUserId] ??= _establishSession(remoteUserId)
        .whenComplete(() {
          _pendingSessions.remove(remoteUserId);
        });
  }

  Future<bool> _establishSession(String remoteUserId) async {
    await initStore();
    final address = _getAddress(remoteUserId);
    if (await _store.containsSession(address)) return true;

    try {
      final response = await _api.getPrekeyBundle(
        remoteUserId,
        deviceId: deviceId,
      );
      final data = ApiService.dataMap(response.data);

      final identityKeyStr = data['identity_key'];
      final signedPreKeyStr = data['signed_prekey'];
      final signatureStr = data['signature'];
      if (identityKeyStr == null ||
          signedPreKeyStr == null ||
          signatureStr == null) {
        debugPrint("E2EE: bundle for $remoteUserId is incomplete");
        return false;
      }

      // One-time prekeys run out; X3DH still works with the signed prekey.
      final otpBody = data['one_time_prekey_body'] as String?;
      final otpId = data['one_time_prekey_id'] as int?;

      final bundle = PreKeyBundle(
        0,
        1,
        otpBody != null ? otpId : null,
        otpBody != null ? Curve.decodePoint(base64Decode(otpBody), 0) : null,
        _signedPreKeyId,
        Curve.decodePoint(base64Decode(signedPreKeyStr), 0),
        base64Decode(signatureStr),
        IdentityKey(Curve.decodePoint(base64Decode(identityKeyStr), 0)),
      );

      await SessionBuilder(
        _store,
        _store,
        _store,
        _store,
        address,
      ).processPreKeyBundle(bundle);
      return true;
    } on DioException catch (e) {
      debugPrint(
        e.response?.statusCode == 404
            ? "E2EE: $remoteUserId has not published keys yet"
            : "E2EE: bundle fetch failed for $remoteUserId: ${e.message}",
      );
      return false;
    } catch (e) {
      debugPrint("E2EE: session setup with $remoteUserId failed: $e");
      return false;
    }
  }

  /// Starts over with a contact: forgets the session and the pinned identity
  /// key (so a reinstalled contact is trusted again), then builds a new one.
  Future<bool> forceResetSession(String remoteUserId) async {
    await initStore();
    final address = _getAddress(remoteUserId);
    await _store.deleteSession(address);
    final db = await DatabaseHelper.instance.database;
    await db.delete(
      'signal_identities',
      where: 'address = ?',
      whereArgs: [address.getName()],
    );
    return establishSessionIfNeeded(remoteUserId);
  }

  Future<void> clearAllSessions() async {
    final db = await DatabaseHelper.instance.database;
    await db.delete('signal_sessions');
  }

  // --- Encryption ---

  /// Encrypts [plaintext] for a contact and returns the wire envelope.
  Future<String> encryptDirect(String remoteUserId, String plaintext) {
    return _serial(() => _encrypt(remoteUserId, plaintext));
  }

  Future<String> _encrypt(String remoteUserId, String plaintext) async {
    await initStore();
    final cipher = SessionCipher(
      _store,
      _store,
      _store,
      _store,
      _getAddress(remoteUserId),
    );
    final message = await cipher.encrypt(
      Uint8List.fromList(utf8.encode(plaintext)),
    );
    return MessageEnvelope(
      message.getType(),
      base64Encode(message.serialize()),
    ).encode();
  }

  /// Turns wire content into readable text. Plaintext envelopes (groups) are
  /// unwrapped, Signal envelopes are decrypted, and failures become a
  /// [MessageEnvelope.locked] placeholder instead of throwing.
  Future<String> decodeIncoming(String senderId, String content) async {
    final envelope = MessageEnvelope.tryParse(content);
    if (envelope == null) return content;
    if (envelope.isPlaintext) return envelope.body;

    try {
      return await _serial(() => _decrypt(senderId, envelope));
    } catch (e) {
      debugPrint("E2EE: decrypt failed from $senderId: $e");
      final error = e.toString();
      if (error.contains('UntrustedIdentity')) {
        return MessageEnvelope.locked(
          'Safety number changed. Reset the secure session to read new messages.',
        );
      }
      if (error.contains('DuplicateMessage')) {
        return MessageEnvelope.locked(
          'Message already decrypted on this device',
        );
      }
      if (error.contains('NoSession') ||
          error.contains('InvalidKeyId') ||
          error.contains('Bad Mac')) {
        return MessageEnvelope.locked('Encrypted for a previous session');
      }
      return MessageEnvelope.locked('Unable to decrypt this message');
    }
  }

  Future<String> _decrypt(String senderId, MessageEnvelope envelope) async {
    await initStore();
    final cipher = SessionCipher(
      _store,
      _store,
      _store,
      _store,
      _getAddress(senderId),
    );
    final bytes = base64Decode(envelope.body);

    final Uint8List plaintext;
    if (envelope.type == CiphertextMessage.prekeyType) {
      plaintext = await cipher.decrypt(PreKeySignalMessage(bytes));
    } else {
      plaintext = await cipher.decryptFromSignal(
        SignalMessage.fromSerialized(bytes),
      );
    }
    return utf8.decode(plaintext);
  }

  // --- Verification ---

  /// Safety number for this pair of users plus the server-side verified flag.
  /// Returns null when no secure session can be established.
  Future<VerificationInfo?> getVerification(
    String localUserId,
    String remoteUserId,
  ) async {
    await initStore();
    if (!await establishSessionIfNeeded(remoteUserId)) return null;

    final remoteIdentity = await _store.getIdentity(_getAddress(remoteUserId));
    if (remoteIdentity == null) return null;

    final localKeyPair = await _store.getIdentityKeyPair();
    final fingerprint = NumericFingerprintGenerator(5200).createFor(
      1,
      Uint8List.fromList(utf8.encode(localUserId)),
      localKeyPair.getPublicKey(),
      Uint8List.fromList(utf8.encode(remoteUserId)),
      remoteIdentity,
    );

    bool isVerified = false;
    try {
      final res = await _api.getVerification(remoteUserId);
      isVerified = ApiService.dataMap(res.data)['is_verified'] == true;
    } catch (e) {
      debugPrint("E2EE: verification lookup failed: $e");
    }

    return VerificationInfo(
      safetyNumber: fingerprint.displayableFingerprint.getDisplayText(),
      isVerified: isVerified,
    );
  }

  Future<void> setVerified(String remoteUserId, bool isVerified) async {
    await _api.setVerification(remoteUserId, isVerified);
  }
}
