import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../services/calls/call_log.dart';
import '../../services/calls/call_media.dart';
import '../../services/calls/call_sounds.dart';

/// Where a call is, from this phone's side.
enum CallPhase {
  idle,

  /// Calling out; the other phone isn't ringing yet.
  calling,

  /// Calling out, and the other phone is ringing.
  ringing,

  /// Someone is calling us.
  incoming,

  /// Answered; the audio is connecting.
  connecting,

  connected,

  /// The call just ended. Shown briefly, then back to [idle].
  ended,
}

/// One-to-one voice calls (see "Calls" in docs/API_CONTRACTS.md).
///
/// The server relays the call setup; the SDP and ICE candidates are
/// encrypted with the Signal session so the server can't read them or swap
/// the keys that protect the audio. Everything the controller talks to is
/// passed in, so tests can run it without WebRTC, a server or Signal.
class CallController extends ChangeNotifier {
  /// The app's controller, used to route WebSocket events and to keep the
  /// connection open during a call.
  static CallController? instance;

  final CallMedia Function() createMedia;
  final CallSounds sounds;
  final CallLog log;

  /// Sends a WebSocket event. Returns false when it couldn't be sent.
  final bool Function(Map<String, dynamic> event) send;

  /// Encrypts text for a contact, and decrypts what they sent (null if it
  /// can't be read).
  final Future<String> Function(String peerId, String text) encrypt;
  final Future<String?> Function(String peerId, String content) decrypt;

  /// The servers for a call, or null if the server doesn't support calls.
  final Future<List<Map<String, dynamic>>?> Function() iceServers;

  /// A contact's display name, for an incoming call.
  final Future<String> Function(String userId) nameOf;

  /// Called when a call comes in, to show the call screen.
  VoidCallback? onIncoming;

  /// How long an answered call may take to connect, and how long a dropped
  /// connection may take to recover, before the call ends.
  final Duration connectTimeout;
  final Duration reconnectTimeout;

  /// How long the "call ended" state is shown.
  final Duration endedFor;

  CallController({
    required this.createMedia,
    required this.sounds,
    required this.log,
    required this.send,
    required this.encrypt,
    required this.decrypt,
    required this.iceServers,
    required this.nameOf,
    this.onIncoming,
    this.connectTimeout = const Duration(seconds: 30),
    this.reconnectTimeout = const Duration(seconds: 15),
    this.endedFor = const Duration(seconds: 2),
  });

  CallPhase phase = CallPhase.idle;
  String? callId;
  String? peerId;
  String peerName = '';
  bool outgoing = false;
  bool muted = false;
  bool speaker = false;
  DateTime? startedAt;
  DateTime? connectedAt;

  /// Why the call ended, e.g. "No answer". Set in [CallPhase.ended].
  String? endedText;

  CallMedia? _media;
  String? _offer;
  bool _remoteReady = false;
  bool _signalOpen = false;
  final List<String> _remoteCandidates = [];
  final List<String> _localCandidates = [];
  Timer? _connectTimer;
  Timer? _reconnectTimer;
  Timer? _endedTimer;

  /// True while a call is ringing, connecting or connected.
  bool get isActive => phase != CallPhase.idle && phase != CallPhase.ended;

  Duration get elapsed => connectedAt == null
      ? Duration.zero
      : DateTime.now().difference(connectedAt!);

  // --- Starting and answering ---

  /// Calls [userId]. Returns a message to show if the call couldn't start.
  Future<String?> call(String userId, String name) async {
    if (isActive) return "You're already in a call";

    _reset();
    final id = const Uuid().v4();
    callId = id;
    peerId = userId.toLowerCase();
    peerName = name;
    outgoing = true;
    startedAt = DateTime.now();
    phase = CallPhase.calling;
    notifyListeners();

    final List<Map<String, dynamic>>? servers;
    try {
      servers = await iceServers();
    } catch (e) {
      debugPrint("Couldn't get call servers: $e");
      return _abort(id, "Couldn't reach the server");
    }
    if (!_isCurrent(id)) return null;
    if (servers == null) {
      return _abort(id, "This server doesn't support calls yet");
    }

    final media = createMedia();
    _media = media;
    try {
      await media.open(
        iceServers: servers,
        onCandidate: (c) => _onLocalCandidate(id, c),
        onState: (s) => _onMediaState(id, s),
      );
      if (!_isCurrent(id)) return _discard(media);
      final offer = await media.createOffer();
      if (!_isCurrent(id)) return _discard(media);
      final content = await encrypt(peerId!, offer);
      if (!_isCurrent(id)) return _discard(media);
      final sent = send({
        'type': 'call_offer',
        'call_id': id,
        'receiver_id': peerId,
        'content': content,
      });
      if (!sent) return _abort(id, "You're offline");
    } catch (e) {
      debugPrint('Call setup failed: $e');
      return _abort(id, _setupError(e));
    }

    _signalOpen = true;
    _flushLocalCandidates(id);
    unawaited(sounds.inCall(true, name: peerName));
    return null;
  }

  /// Answers the incoming call.
  Future<void> accept() async {
    final id = callId;
    final offer = _offer;
    if (phase != CallPhase.incoming || id == null || offer == null) return;

    phase = CallPhase.connecting;
    unawaited(sounds.stop());
    notifyListeners();

    try {
      final servers = await iceServers() ?? const [];
      if (!_isCurrent(id)) return;
      final media = createMedia();
      _media = media;
      await media.open(
        iceServers: servers,
        onCandidate: (c) => _onLocalCandidate(id, c),
        onState: (s) => _onMediaState(id, s),
      );
      if (!_isCurrent(id)) return _discard(media);
      final answer = await media.answer(offer);
      if (!_isCurrent(id)) return _discard(media);
      _remoteReady = true;
      await _flushRemoteCandidates();
      final content = await encrypt(peerId!, answer);
      if (!_isCurrent(id)) return;
      send({'type': 'call_answer', 'call_id': id, 'content': content});
    } catch (e) {
      debugPrint('Answering failed: $e');
      if (_isCurrent(id)) {
        _finish(_setupError(e), CallOutcome.failed, hangup: 'ended');
      }
      return;
    }

    _signalOpen = true;
    _flushLocalCandidates(id);
    unawaited(sounds.inCall(true, name: peerName));
    _startConnectTimer(id);
  }

  /// Declines the incoming call.
  void decline() {
    if (phase != CallPhase.incoming) return;
    _finish('Declined', CallOutcome.declined, hangup: 'declined');
  }

  /// Ends the call, or cancels it if it hasn't been answered.
  void hangUp() {
    switch (phase) {
      case CallPhase.idle:
      case CallPhase.ended:
        return;
      case CallPhase.incoming:
        decline();
      case CallPhase.calling:
      case CallPhase.ringing:
        _finish('Cancelled', CallOutcome.cancelled, hangup: 'ended');
      case CallPhase.connecting:
      case CallPhase.connected:
        _finish('Call ended', _answeredOrFailed(), hangup: 'ended');
    }
  }

  void toggleMute() {
    muted = !muted;
    _media?.setMuted(muted);
    notifyListeners();
  }

  Future<void> toggleSpeaker() async {
    speaker = !speaker;
    notifyListeners();
    await _media?.setSpeaker(speaker);
  }

  // --- Events from the server ---

  /// Handles a `call_*` WebSocket event.
  Future<void> handleEvent(Map<String, dynamic> data) async {
    final id = data['call_id']?.toString();
    if (id == null || id.isEmpty) return;

    switch (data['type']) {
      case 'call_offer':
        await _onOffer(id, data);
      case 'call_ring':
        if (_isCurrent(id) && phase == CallPhase.calling) {
          phase = CallPhase.ringing;
          unawaited(sounds.ringback());
          notifyListeners();
        }
      case 'call_answer':
        await _onAnswer(id, data);
      case 'call_ice':
        await _onRemoteCandidate(id, data);
      case 'call_busy':
        if (_isCurrent(id) && outgoing) _finish('Busy', CallOutcome.busy);
      case 'call_hangup':
        if (_isCurrent(id)) _onRemoteHangup(data['reason']?.toString());
    }
  }

  Future<void> _onOffer(String id, Map<String, dynamic> data) async {
    final from = data['sender_id']?.toString().toLowerCase();
    if (from == null || from.isEmpty || isActive) return;

    final offer = await decrypt(from, data['content']?.toString() ?? '');
    if (offer == null) {
      // We can't read it, so we can't answer. Let the caller know at once.
      send({'type': 'call_hangup', 'call_id': id, 'reason': 'ended'});
      await log.add(
        CallLogEntry(
          id: id,
          chatId: from,
          outgoing: false,
          outcome: CallOutcome.failed,
          startedAt: DateTime.now(),
        ),
      );
      return;
    }
    if (isActive) return;

    _reset();
    callId = id;
    peerId = from;
    outgoing = false;
    startedAt = DateTime.now();
    _offer = offer;
    peerName = '';
    phase = CallPhase.incoming;
    notifyListeners();

    send({'type': 'call_ring', 'call_id': id});
    unawaited(sounds.ring());
    onIncoming?.call();

    // Ring straight away; the name follows when it's known.
    final name = await nameOf(
      from,
    ).timeout(const Duration(seconds: 3), onTimeout: () => 'Someone');
    if (_isCurrent(id)) {
      peerName = name;
      notifyListeners();
    }
  }

  Future<void> _onAnswer(String id, Map<String, dynamic> data) async {
    if (!_isCurrent(id) || !outgoing) return;
    if (phase != CallPhase.calling && phase != CallPhase.ringing) return;

    final answer = await decrypt(peerId!, data['content']?.toString() ?? '');
    if (!_isCurrent(id)) return;
    if (answer == null) {
      _finish("Couldn't connect", CallOutcome.failed, hangup: 'ended');
      return;
    }
    phase = CallPhase.connecting;
    unawaited(sounds.stop());
    notifyListeners();
    try {
      await _media?.acceptAnswer(answer);
      _remoteReady = true;
      await _flushRemoteCandidates();
    } catch (e) {
      debugPrint('Applying the answer failed: $e');
      if (_isCurrent(id)) {
        _finish("Couldn't connect", CallOutcome.failed, hangup: 'ended');
      }
      return;
    }
    _startConnectTimer(id);
  }

  Future<void> _onRemoteCandidate(String id, Map<String, dynamic> data) async {
    if (!_isCurrent(id)) return;
    final candidate = await decrypt(peerId!, data['content']?.toString() ?? '');
    if (candidate == null || !_isCurrent(id)) return;
    if (!_remoteReady) {
      // Candidates can arrive before the offer is answered or the answer is
      // applied. They're added once the other side's description is set.
      _remoteCandidates.add(candidate);
      return;
    }
    try {
      await _media?.addCandidate(candidate);
    } catch (e) {
      debugPrint('Adding a candidate failed: $e');
    }
  }

  void _onRemoteHangup(String? reason) {
    switch (phase) {
      case CallPhase.incoming:
        _finish('Missed call', CallOutcome.missed);
      case CallPhase.calling:
      case CallPhase.ringing:
        switch (reason) {
          case 'declined':
            _finish('Declined', CallOutcome.declined);
          case 'timeout':
            _finish('No answer', CallOutcome.noAnswer);
          case 'unavailable':
            _finish('Unavailable', CallOutcome.unavailable);
          default:
            _finish('Call ended', CallOutcome.noAnswer);
        }
      case CallPhase.connecting:
      case CallPhase.connected:
        _finish(
          reason == 'disconnected' ? 'Connection lost' : 'Call ended',
          _answeredOrFailed(),
        );
      case CallPhase.idle:
      case CallPhase.ended:
        break;
    }
  }

  // --- Media ---

  void _onLocalCandidate(String id, String candidate) {
    if (!_isCurrent(id)) return;
    _localCandidates.add(candidate);
    // The server only relays candidates for a call it knows about, so they
    // wait until the offer (or answer) has gone.
    if (_signalOpen) _flushLocalCandidates(id);
  }

  void _flushLocalCandidates(String id) {
    final pending = List.of(_localCandidates);
    _localCandidates.clear();
    for (final c in pending) {
      encrypt(peerId!, c).then((content) {
        if (_isCurrent(id)) {
          send({'type': 'call_ice', 'call_id': id, 'content': content});
        }
      });
    }
  }

  Future<void> _flushRemoteCandidates() async {
    final pending = List.of(_remoteCandidates);
    _remoteCandidates.clear();
    for (final c in pending) {
      try {
        await _media?.addCandidate(c);
      } catch (e) {
        debugPrint('Adding a candidate failed: $e');
      }
    }
  }

  void _onMediaState(String id, MediaState state) {
    if (!_isCurrent(id)) return;
    switch (state) {
      case MediaState.connected:
        _reconnectTimer?.cancel();
        _connectTimer?.cancel();
        if (phase != CallPhase.connected) {
          phase = CallPhase.connected;
          connectedAt ??= DateTime.now();
          unawaited(sounds.stop());
          notifyListeners();
        }
      case MediaState.disconnected:
        // Often recovers on its own, e.g. when switching networks.
        _reconnectTimer?.cancel();
        _reconnectTimer = Timer(reconnectTimeout, () {
          if (_isCurrent(id) && isActive) {
            _finish('Connection lost', _answeredOrFailed(), hangup: 'ended');
          }
        });
      case MediaState.failed:
        if (phase == CallPhase.connecting || phase == CallPhase.connected) {
          _finish(
            connectedAt == null ? "Couldn't connect" : 'Connection lost',
            _answeredOrFailed(),
            hangup: 'ended',
          );
        }
      case MediaState.connecting:
        break;
    }
  }

  void _startConnectTimer(String id) {
    _connectTimer?.cancel();
    _connectTimer = Timer(connectTimeout, () {
      if (_isCurrent(id) && phase == CallPhase.connecting) {
        _finish("Couldn't connect", CallOutcome.failed, hangup: 'ended');
      }
    });
  }

  // --- Ending ---

  CallOutcome _answeredOrFailed() =>
      connectedAt == null ? CallOutcome.failed : CallOutcome.answered;

  /// Ends the call: tells the other side if [hangup] is set, stops the audio,
  /// records it in the chat, and shows [text] briefly.
  void _finish(String text, CallOutcome outcome, {String? hangup}) {
    final id = callId;
    final peer = peerId;
    if (id == null || peer == null || !isActive) return;

    if (hangup != null) {
      send({'type': 'call_hangup', 'call_id': id, 'reason': hangup});
    }
    final duration = connectedAt == null
        ? Duration.zero
        : DateTime.now().difference(connectedAt!);
    _stop();

    unawaited(
      log.add(
        CallLogEntry(
          id: id,
          chatId: peer,
          outgoing: outgoing,
          outcome: outcome,
          startedAt: startedAt ?? DateTime.now(),
          duration: duration,
        ),
      ),
    );

    phase = CallPhase.ended;
    endedText = text;
    notifyListeners();
    _endedTimer = Timer(endedFor, () {
      if (phase == CallPhase.ended && callId == id) {
        phase = CallPhase.idle;
        notifyListeners();
      }
    });
  }

  /// Ends a call that never reached the server. Nothing is logged.
  String _abort(String id, String message) {
    if (_isCurrent(id)) {
      _stop();
      phase = CallPhase.idle;
      notifyListeners();
    }
    return message;
  }

  /// Closes media opened for a call that ended while it was being set up.
  Null _discard(CallMedia media) {
    if (!identical(media, _media)) unawaited(media.close());
    return null;
  }

  void _stop() {
    _connectTimer?.cancel();
    _reconnectTimer?.cancel();
    unawaited(sounds.stop());
    unawaited(sounds.inCall(false));
    final media = _media;
    _media = null;
    unawaited(media?.close());
  }

  void _reset() {
    _endedTimer?.cancel();
    _offer = null;
    _remoteReady = false;
    _signalOpen = false;
    _remoteCandidates.clear();
    _localCandidates.clear();
    muted = false;
    speaker = false;
    connectedAt = null;
    endedText = null;
  }

  /// Whether [id] is the call in progress. An async step that finds it isn't
  /// (the call ended, or another began) stops.
  bool _isCurrent(String id) => callId == id && isActive;

  String _setupError(Object e) {
    final text = e.toString().toLowerCase();
    if (text.contains('permission') || text.contains('notallowed')) {
      return 'Elephant needs the microphone for calls. Allow it in Settings.';
    }
    return "Couldn't start the call";
  }

  @override
  void dispose() {
    _endedTimer?.cancel();
    _stop();
    super.dispose();
  }
}
