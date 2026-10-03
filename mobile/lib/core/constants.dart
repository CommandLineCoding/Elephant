// lib/core/constants.dart
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class Env {
  static const String defaultHost = "elephant.commandlinecoding.in";
  static const String defaultPort = "443";

  static String host = defaultHost;
  static String port = defaultPort;

  static bool get _isSecure =>
      port == "443" || host.contains("commandlinecoding.in");

  static String get httpBaseUrl {
    final protocol = _isSecure ? "https" : "http";
    final portSuffix = (port == "80" || port == "443") ? "" : ":$port";
    return "$protocol://$host$portSuffix/api";
  }

  static String get wsBaseUrl {
    final protocol = _isSecure ? "wss" : "ws";
    final portSuffix = (port == "80" || port == "443") ? "" : ":$port";
    return "$protocol://$host$portSuffix/api/ws";
  }

  static bool get isDefaultServer => host == defaultHost && port == defaultPort;

  static Future<void> init() async {
    const storage = FlutterSecureStorage();
    host = await storage.read(key: "custom_host") ?? defaultHost;
    port = await storage.read(key: "custom_port") ?? defaultPort;
  }

  static Future<void> updateConfig(String newHost, String newPort) async {
    host = newHost.trim().isEmpty ? defaultHost : newHost.trim();
    port = newPort.trim().isEmpty ? defaultPort : newPort.trim();

    const storage = FlutterSecureStorage();
    await storage.write(key: "custom_host", value: host);
    await storage.write(key: "custom_port", value: port);
  }
}

/// Limits enforced by the Elephant server (see docs/API_CONTRACTS.md).
class ServerLimits {
  /// The server closes any WebSocket whose inbound frame exceeds 4096 bytes.
  static const int maxWsFrameBytes = 4096;

  /// Plaintext budget per message. Signal ciphertext, base64 and the JSON
  /// envelope grow a direct message ~1.5x on the wire; 2400 bytes encrypts to
  /// ~3.6 KB (checked by test/frame_budget_test.dart).
  static const int maxDirectMessageBytes = 2400;
  static const int maxGroupMessageBytes = 3200;

  /// Messages can only be edited within this window of being sent.
  static const Duration editWindow = Duration(minutes: 15);

  static const int historyPageSize = 50;
  static const int searchPageSize = 20;

  static const int usernameMin = 3;
  static const int usernameMax = 25;
  static const int passwordMin = 8;
}
