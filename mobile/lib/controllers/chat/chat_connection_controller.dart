import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:mobile/services/chat/chat_event_handler.dart';
import 'package:mobile/services/chat/chat_sync_service.dart';
import '../../services/ws_service.dart';
import '../../services/auth_service.dart';

enum ConnectionStatus { connected, connecting, offline }

class ChatConnectionController extends ChangeNotifier
    with WidgetsBindingObserver {
  final WebSocketService _ws = WebSocketService();
  final AuthService _auth = AuthService();
  final ChatSyncService _syncService = ChatSyncService();
  final ChatEventHandler eventHandler;

  bool isOffline = false;
  ConnectionStatus status = ConnectionStatus.connecting;

  bool _isWsConnecting = false;
  bool _isPaused = false;
  int _failedAttempts = 0;
  Timer? _reconnectTimer;
  StreamSubscription? _connectivitySubscription;
  StreamSubscription? _wsSubscription;

  ChatConnectionController({required this.eventHandler}) {
    WidgetsBinding.instance.addObserver(this);

    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
      result,
    ) {
      final bool currentlyOffline = result.contains(ConnectivityResult.none);
      if (isOffline == currentlyOffline) return;

      isOffline = currentlyOffline;
      if (isOffline) {
        _markPeerOffline();
        _wsSubscription?.cancel();
        _ws.disconnect();
        _setStatus(ConnectionStatus.offline);
      } else {
        _failedAttempts = 0;
        connectWebSocket();
        eventHandler.inboxController.loadInbox();
      }
    });
  }

  void _setStatus(ConnectionStatus next) {
    if (status != next) {
      status = next;
      notifyListeners();
    }
  }

  void _markPeerOffline() {
    final chat = eventHandler.activeChatController;
    if (chat.isPeerOnline || chat.isPeerTyping) {
      chat.isPeerOnline = false;
      chat.isPeerTyping = false;
      chat.refreshUI();
    }
  }

  Future<void> connectWebSocket() async {
    if (_ws.isConnected || _isWsConnecting || isOffline || _isPaused) return;
    _isWsConnecting = true;
    _reconnectTimer?.cancel();
    _setStatus(ConnectionStatus.connecting);

    try {
      // Access tokens live 15 minutes, so refresh before every handshake.
      final token = await _auth.getValidAccessToken();
      if (token == null) return;

      await _wsSubscription?.cancel();
      _ws.disconnect();

      if (!await _ws.connect(token)) {
        _scheduleReconnect();
        return;
      }

      _failedAttempts = 0;
      _setStatus(ConnectionStatus.connected);

      _wsSubscription = _ws.stream?.listen(
        (rawFrame) {
          try {
            final decoded = jsonDecode(rawFrame);
            if (decoded is Map<String, dynamic>) {
              eventHandler.handleIncomingEvent(decoded);
            }
          } catch (e) {
            debugPrint("WebSocket payload error: $e");
          }
        },
        onError: (err) {
          debugPrint("WS error: $err");
          _scheduleReconnect();
        },
        onDone: () {
          debugPrint("WS closed");
          _scheduleReconnect();
        },
        cancelOnError: true,
      );

      _syncService.processOfflineQueue(
        eventHandler.currentUserId,
        activeChatController: eventHandler.activeChatController,
      );

      final chat = eventHandler.activeChatController;
      if (chat.currentChatUserId != null && !chat.isCurrentChatGroup) {
        _ws.sendRequestStatus(targetId: chat.currentChatUserId!);
      }
    } catch (e) {
      debugPrint("WS setup error: $e");
      _scheduleReconnect();
    } finally {
      _isWsConnecting = false;
    }
  }

  void _scheduleReconnect() {
    _ws.disconnect();
    _isWsConnecting = false;
    _markPeerOffline();
    if (isOffline || _isPaused) return;

    _setStatus(ConnectionStatus.connecting);
    _failedAttempts++;
    final seconds = min(30, 2 * pow(2, min(_failedAttempts - 1, 4)).toInt());

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: seconds), connectWebSocket);
  }

  /// Reconnect immediately, e.g. from a "Retry" button.
  void retryNow() {
    _failedAttempts = 0;
    connectWebSocket();
  }

  void disconnectWebSocket() {
    _reconnectTimer?.cancel();
    _wsSubscription?.cancel();
    _ws.disconnect();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _isPaused = false;
      connectWebSocket();
      if (!isOffline) {
        eventHandler.inboxController.loadInbox();
        eventHandler.activeChatController.syncActiveChatSilently();
      }
    } else if (state == AppLifecycleState.paused) {
      _isPaused = true;
      disconnectWebSocket();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectivitySubscription?.cancel();
    disconnectWebSocket();
    super.dispose();
  }
}
