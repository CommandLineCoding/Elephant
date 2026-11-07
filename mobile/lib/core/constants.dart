// lib/core/constants.dart
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class Env {
  static const String defaultHost = "elephant.commandlinecoding.in";
  static const String defaultPort = "443";

  static String host = defaultHost;
  static String port = defaultPort;

  /// Whether to use HTTPS/WSS. Chosen explicitly in Server settings so a
  /// self-hosted TLS server on a non-443 port isn't contacted in plain text.
  static bool useTls = true;

  static String get httpBaseUrl =>
      buildUrl(host: host, port: port, tls: useTls, path: '/api');

  static String get wsBaseUrl =>
      buildUrl(host: host, port: port, tls: useTls, path: '/api/ws', ws: true);

  /// Builds a server URL, omitting the port when it's the scheme's default.
  static String buildUrl({
    required String host,
    required String port,
    required bool tls,
    required String path,
    bool ws = false,
  }) {
    final scheme = ws ? (tls ? 'wss' : 'ws') : (tls ? 'https' : 'http');
    final isDefaultPort = port == (tls ? '443' : '80');
    return '$scheme://$host${isDefaultPort ? '' : ':$port'}$path';
  }

  static bool get isDefaultServer => host == defaultHost && port == defaultPort;

  static Future<void> init() async {
    const storage = FlutterSecureStorage();
    host = await storage.read(key: "custom_host") ?? defaultHost;
    port = await storage.read(key: "custom_port") ?? defaultPort;
    final storedTls = await storage.read(key: "custom_use_tls");
    // Servers saved before the setting existed keep their old behaviour.
    useTls = storedTls != null
        ? storedTls == "true"
        : port == "443" || host.contains("commandlinecoding.in");
  }

  static Future<void> updateConfig(
    String newHost,
    String newPort, {
    bool tls = true,
  }) async {
    host = newHost.trim().isEmpty ? defaultHost : newHost.trim();
    port = newPort.trim().isEmpty ? defaultPort : newPort.trim();
    useTls = tls;

    const storage = FlutterSecureStorage();
    await storage.write(key: "custom_host", value: host);
    await storage.write(key: "custom_port", value: port);
    await storage.write(key: "custom_use_tls", value: useTls.toString());
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
