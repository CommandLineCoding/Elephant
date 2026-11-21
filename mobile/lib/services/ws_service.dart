import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../core/constants.dart';
import 'privacy_settings.dart';

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
  /// exceed the server's limit (which would close the socket): 4096 bytes, or
  /// 64 KB for call setup.
  bool emit(Map<String, dynamic> payload) {
    if (!_isConnected || _channel == null) return false;

    payload.removeWhere((_, value) => value == null);
    final encoded = jsonEncode(payload);
    final limit = _isCallSignal(payload['type'])
        ? ServerLimits.maxCallFrameBytes
        : ServerLimits.maxWsFrameBytes;
    if (utf8.encode(encoded).length > limit) {
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

  static bool _isCallSignal(Object? type) =>
      type == 'call_offer' || type == 'call_answer' || type == 'call_ice';

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
    bool silent = false,
  }) {
    return {
      "type": "chat",
      "message_id": messageId,
      "receiver_id": receiverId,
      "group_id": groupId,
      "content": content,
      "reply_to_message_id": replyToMessageId,
      // Only sent when set: servers before this flag ignore it.
      "silent": silent ? true : null,
    };
  }

  bool sendChat({
    required String messageId,
    required String receiverId,
    required String content,
    String? replyToMessageId,
    bool silent = false,
  }) {
    return emit(
      chatFrame(
        messageId: messageId,
        receiverId: receiverId,
        content: content,
        replyToMessageId: replyToMessageId,
        silent: silent,
      ),
    );
  }

  bool sendGroupChat({
    required String messageId,
    required String groupId,
    required String content,
    String? replyToMessageId,
    bool silent = false,
  }) {
    return emit(
      chatFrame(
        messageId: messageId,
        groupId: groupId,
        content: content,
        replyToMessageId: replyToMessageId,
        silent: silent,
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
    final frame = readReceiptFrame(
      receiverId: receiverId,
      groupId: groupId,
      enabled: PrivacySettings.instance.readReceipts,
    );
    if (frame != null) emit(frame);
  }

  /// The frame that tells someone their messages were read, or null while read
  /// receipts are off: then nobody is told. (The server drops them too.)
  static Map<String, dynamic>? readReceiptFrame({
    String? receiverId,
    String? groupId,
    required bool enabled,
  }) {
    if (!enabled) return null;
    return {
      "type": "read_receipt",
      "receiver_id": receiverId,
      "group_id": groupId,
    };
  }

  /// Tells the server these direct messages reached this phone, so their
  /// senders can show a second tick.
  void sendDelivered(List<String> messageIds) {
    for (final frame in deliveredFrames(messageIds)) {
      emit(frame);
    }
  }

  /// `delivered` frames for [messageIds]: the server takes at most 100 IDs in
  /// one.
  static List<Map<String, dynamic>> deliveredFrames(List<String> messageIds) {
    return [
      for (var i = 0; i < messageIds.length; i += 100)
        {
          "type": "delivered",
          "message_ids": messageIds.sublist(
            i,
            i + 100 > messageIds.length ? messageIds.length : i + 100,
          ),
        },
    ];
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
