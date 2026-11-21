import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:mobile/controllers/call/call_controller.dart';
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
  DateTime? _lastSignInCheck;
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

  /// Renews the sign-in. If the server says it has ended (this device was
  /// signed out from another), [AuthService] signs out here. Any other
  /// failure, such as being offline, is left for the reconnect to deal with.
  Future<void> _checkSignIn() async {
    // Not on every retry: once a minute is plenty.
    final last = _lastSignInCheck;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(minutes: 1)) {
      return;
    }
    _lastSignInCheck = DateTime.now();
    try {
      await _auth.refreshTokens();
    } on SessionExpiredException {
      // AuthService has already signed this device out.
    } catch (e) {
      debugPrint("Sign-in check failed: $e");
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
        // The server turns a signed-out device away. Its access token still
        // looks valid for a while, so renew it now: that finds out the sign-in
        // is over and returns to the sign-in screen, instead of retrying.
        unawaited(_checkSignIn());
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
      // A call goes on in the background, and needs the connection to end.
      if (CallController.instance?.isActive ?? false) return;
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
