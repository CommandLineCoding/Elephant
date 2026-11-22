import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Where a backup file goes to and comes from: wherever the person picks, with
/// Android's file picker (this phone, a USB drive, a cloud app).
abstract class BackupFiles {
  /// Lets the person choose where to keep [bytes]. Returns whether it was
  /// saved: false if they backed out.
  Future<bool> save(String fileName, Uint8List bytes);

  /// Lets the person choose a backup file. Null if they backed out.
  Future<Uint8List?> pick();
}

class PickerBackupFiles implements BackupFiles {
  const PickerBackupFiles();

  @override
  Future<bool> save(String fileName, Uint8List bytes) async {
    final path = await FilePicker.saveFile(
      dialogTitle: 'Save your backup',
      fileName: fileName,
      bytes: bytes,
    );
    return path != null;
  }

  @override
  Future<Uint8List?> pick() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Choose a backup',
      withData: true,
    );
    return result?.files.single.bytes;
  }
}

/// ["elephant-backup-2026-11-22.elbk"]
String backupFileName(DateTime when) {
  String two(int n) => n.toString().padLeft(2, '0');
  return 'elephant-backup-${when.year}-${two(when.month)}-${two(when.day)}.elbk';
}
