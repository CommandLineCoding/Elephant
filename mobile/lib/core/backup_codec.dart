import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Why a backup couldn't be opened.
enum BackupProblem {
  /// Not an Elephant backup file, or damaged.
  notABackup,

  /// A backup made by a newer version of the app.
  tooNew,

  /// The passphrase is wrong, or the file was changed.
  wrongPassphrase,

  /// A backup of another account's chats.
  otherAccount,
}

class BackupException implements Exception {
  final BackupProblem problem;

  const BackupException(this.problem);

  String get message => switch (problem) {
    BackupProblem.notABackup => 'This isn\'t an Elephant backup.',
    BackupProblem.tooNew =>
      'This backup was made by a newer version of Elephant. Update the app '
          'to restore it.',
    BackupProblem.wrongPassphrase =>
      'That passphrase doesn\'t open this backup. Check it and try again.',
    BackupProblem.otherAccount =>
      'This backup is from a different account. Sign in to that account to '
          'restore it.',
  };

  @override
  String toString() => 'BackupException($problem)';
}

/// How hard it is to guess a passphrase: scrypt's cost, stored in the file so
/// a later version can raise it and still open older backups.
class BackupCost {
  /// log2 of scrypt's N.
  final int logN;
  final int r;
  final int p;

  const BackupCost({this.logN = 15, this.r = 8, this.p = 1});

  /// Cheap, for tests.
  static const testing = BackupCost(logN: 4, r: 1, p: 1);
}

/// The encrypted file format of a backup.
///
/// ```
/// "ELEPHBK" | version (1) | logN | r | p | salt (16) | nonce (12) | AES-256-GCM(gzip(json)) + tag
/// ```
///
/// The key comes from the passphrase with scrypt. The header is authenticated
/// along with the contents, so changing the cost or the salt makes the file
/// unreadable rather than weaker.
class BackupCodec {
  static const magic = 'ELEPHBK';
  static const version = 1;

  /// The most memory a backup's settings may ask scrypt for.
  static const maxMemory = 256 * 1024 * 1024;
  static const _saltLength = 16;
  static const _nonceLength = 12;
  static const _headerLength = 7 + 1 + 3 + _saltLength + _nonceLength;

  /// A passphrase to protect a backup with: 30 random digits (about 100 bits),
  /// as ["12345 67890 …"] in six groups.
  static String generatePassphrase([Random? random]) {
    final rng = random ?? Random.secure();
    final digits = List.generate(30, (_) => rng.nextInt(10)).join();
    return [
      for (var i = 0; i < 30; i += 5) digits.substring(i, i + 5),
    ].join(' ');
  }

  /// The passphrase as it is used: spaces and dashes (which only make it
  /// easier to read and type) don't count.
  static String normalize(String passphrase) =>
      passphrase.replaceAll(RegExp(r'[\s-]'), '');

  /// Encrypts [snapshot] with [passphrase]. Runs off the UI thread.
  static Future<Uint8List> seal(
    Map<String, Object?> snapshot,
    String passphrase, {
    BackupCost cost = const BackupCost(),
  }) {
    final json = jsonEncode(snapshot);
    final normalized = normalize(passphrase);
    final salt = _random(_saltLength);
    final nonce = _random(_nonceLength);
    return Isolate.run(() => _seal(json, normalized, cost, salt, nonce));
  }

  /// Decrypts [file]. Throws a [BackupException] if it isn't a backup, is from
  /// a newer app, or [passphrase] is wrong.
  static Future<Map<String, Object?>> open(Uint8List file, String passphrase) {
    final normalized = normalize(passphrase);
    return Isolate.run(() => _open(file, normalized));
  }

  static Uint8List _random(int length) {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(length, (_) => rng.nextInt(256)));
  }

  static Uint8List _key(String passphrase, BackupCost cost, Uint8List salt) {
    final scrypt = Scrypt()
      ..init(ScryptParameters(1 << cost.logN, cost.r, cost.p, 32, salt));
    return scrypt.process(Uint8List.fromList(utf8.encode(passphrase)));
  }

  static Uint8List _seal(
    String json,
    String passphrase,
    BackupCost cost,
    Uint8List salt,
    Uint8List nonce,
  ) {
    final header = BytesBuilder()
      ..add(ascii.encode(magic))
      ..addByte(version)
      ..addByte(cost.logN)
      ..addByte(cost.r)
      ..addByte(cost.p)
      ..add(salt)
      ..add(nonce);
    final head = header.toBytes();

    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters(
          KeyParameter(_key(passphrase, cost, salt)),
          128,
          nonce,
          head,
        ),
      );
    final body = cipher.process(
      Uint8List.fromList(gzip.encode(utf8.encode(json))),
    );
    return (BytesBuilder()
          ..add(head)
          ..add(body))
        .toBytes();
  }

  static Map<String, Object?> _open(Uint8List file, String passphrase) {
    if (file.length < _headerLength + 16 ||
        ascii.decode(file.sublist(0, 7), allowInvalid: true) != magic) {
      throw const BackupException(BackupProblem.notABackup);
    }
    if (file[7] > version) throw const BackupException(BackupProblem.tooNew);
    if (file[7] != version) {
      throw const BackupException(BackupProblem.notABackup);
    }
    final cost = BackupCost(logN: file[8], r: file[9], p: file[10]);
    // A damaged header mustn't ask for gigabytes of memory: scrypt needs about
    // 128 * N * r bytes. (The app's own settings take 32 MiB.)
    if (cost.logN < 1 || cost.logN > 22 || cost.r < 1 || cost.r > 16) {
      throw const BackupException(BackupProblem.notABackup);
    }
    if (128 * (1 << cost.logN) * cost.r > maxMemory) {
      throw const BackupException(BackupProblem.notABackup);
    }
    if (cost.p < 1 || cost.p > 4) {
      throw const BackupException(BackupProblem.notABackup);
    }
    final salt = file.sublist(11, 11 + _saltLength);
    final nonce = file.sublist(11 + _saltLength, _headerLength);
    final head = file.sublist(0, _headerLength);

    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(
          KeyParameter(_key(passphrase, cost, salt)),
          128,
          nonce,
          head,
        ),
      );
    final Uint8List plain;
    try {
      plain = cipher.process(file.sublist(_headerLength));
    } on InvalidCipherTextException {
      throw const BackupException(BackupProblem.wrongPassphrase);
    }
    try {
      final decoded = jsonDecode(utf8.decode(gzip.decode(plain)));
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      return decoded;
    } on FormatException {
      throw const BackupException(BackupProblem.notABackup);
    } on ArgumentError {
      throw const BackupException(BackupProblem.notABackup);
    }
  }
}
