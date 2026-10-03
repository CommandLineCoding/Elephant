import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../core/constants.dart';

/// WebSocket link to `/api/ws`.
///
/// Liveness relies on protocol-level pings: the server pings every 54s and
/// this client pings every 25s. A missed pong closes the stream, and
/// [ChatConnectionController] reconnects. The server has no application-level
/// ping/pong event.
class WebSocketService {
  static final WebSocketService _instance = WebSocketService._internal();
  factory WebSocketService() => _instance;
  WebSocketService._internal();

  WebSocketChannel? _channel;
  bool _isConnected = false;

  Stream<dynamic>? _broadcastStream;
  Stream<dynamic>? get stream => _broadcastStream;
  bool get isConnected => _isConnected;

  Future<bool> connect(String token) async {
    if (_isConnected) return true;
    try {
      final wsUrl = Uri.parse(
        "${Env.wsBaseUrl}?token=${Uri.encodeQueryComponent(token)}",
      );
      _channel = IOWebSocketChannel.connect(
        wsUrl,
        pingInterval: const Duration(seconds: 25),
        connectTimeout: const Duration(seconds: 10),
      );
      await _channel!.ready;

      _broadcastStream = _channel!.stream.asBroadcastStream();
      _isConnected = true;
      debugPrint("WebSocket connected to ${Env.wsBaseUrl}");
      return true;
    } catch (e) {
      _isConnected = false;
      _channel = null;
      debugPrint("WebSocket connection failure: $e");
      return false;
    }
  }

  /// Sends a frame. Returns false when disconnected or when the frame would
  /// exceed the server's 4096-byte limit (which would close the socket).
  bool emit(Map<String, dynamic> payload) {
    if (!_isConnected || _channel == null) return false;

    payload.removeWhere((_, value) => value == null);
    final encoded = jsonEncode(payload);
    if (utf8.encode(encoded).length > ServerLimits.maxWsFrameBytes) {
      debugPrint(
        "WS: frame of type ${payload['type']} exceeds the server limit",
      );
      return false;
    }

    try {
      _channel!.sink.add(encoded);
      return true;
    } catch (e) {
      debugPrint("WS: write error: $e");
      disconnect();
      return false;
    }
  }

  static int frameSize(Map<String, dynamic> payload) {
    payload.removeWhere((_, value) => value == null);
    return utf8.encode(jsonEncode(payload)).length;
  }

  static Map<String, dynamic> chatFrame({
    required String messageId,
    String? receiverId,
    String? groupId,
    required String content,
    String? replyToMessageId,
  }) {
    return {
      "type": "chat",
      "message_id": messageId,
      "receiver_id": receiverId,
      "group_id": groupId,
      "content": content,
      "reply_to_message_id": replyToMessageId,
    };
  }

  bool sendChat({
    required String messageId,
    required String receiverId,
    required String content,
    String? replyToMessageId,
  }) {
    return emit(
      chatFrame(
        messageId: messageId,
        receiverId: receiverId,
        content: content,
        replyToMessageId: replyToMessageId,
      ),
    );
  }

  bool sendGroupChat({
    required String messageId,
    required String groupId,
    required String content,
    String? replyToMessageId,
  }) {
    return emit(
      chatFrame(
        messageId: messageId,
        groupId: groupId,
        content: content,
        replyToMessageId: replyToMessageId,
      ),
    );
  }

  void sendTyping({
    String? receiverId,
    String? groupId,
    required bool isTyping,
  }) {
    emit({
      "type": "typing",
      "receiver_id": receiverId,
      "group_id": groupId,
      "content": isTyping.toString(),
    });
  }

  void sendReadReceipt({String? receiverId, String? groupId}) {
    emit({
      "type": "read_receipt",
      "receiver_id": receiverId,
      "group_id": groupId,
    });
  }

  void sendRequestStatus({required String targetId}) {
    emit({"type": "request_status", "receiver_id": targetId});
  }

  void disconnect() {
    try {
      _channel?.sink.close();
    } catch (_) {}
    _isConnected = false;
    _channel = null;
    _broadcastStream = null;
  }
}
