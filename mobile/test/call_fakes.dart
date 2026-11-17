import 'dart:async';

import 'package:mobile/controllers/call/call_controller.dart';
import 'package:mobile/services/calls/call_log.dart';
import 'package:mobile/services/calls/call_media.dart';
import 'package:mobile/services/calls/call_sounds.dart';

/// Fakes for the call tests: a CallController wired to recording stand-ins
/// for WebRTC, the WebSocket, Signal and the phone's sounds.

/// Records what the controller asks of the audio side.
class FakeMedia implements CallMedia {
  final List<String> added = [];
  final List<String> log = [];
  void Function(String)? onCandidate;
  void Function(MediaState)? onState;
  bool closed = false;
  bool muted = false;
  bool speaker = false;
  Object? openError;
  Completer<void>? openGate;

  @override
  Future<void> open({
    required List<Map<String, dynamic>> iceServers,
    required void Function(String candidate) onCandidate,
    required void Function(MediaState state) onState,
  }) async {
    log.add('open ${iceServers.length}');
    if (openGate != null) await openGate!.future;
    if (openError != null) throw openError!;
    this.onCandidate = onCandidate;
    this.onState = onState;
  }

  @override
  Future<String> createOffer() async {
    log.add('offer');
    // Candidates start as soon as the local description is set.
    onCandidate?.call('cand-early');
    return 'OFFER';
  }

  @override
  Future<String> answer(String offer) async {
    log.add('answer to $offer');
    return 'ANSWER';
  }

  @override
  Future<void> acceptAnswer(String answer) async => log.add('accept $answer');

  @override
  Future<void> addCandidate(String candidate) async => added.add(candidate);

  @override
  void setMuted(bool muted) => this.muted = muted;

  @override
  Future<void> setSpeaker(bool on) async => speaker = on;

  @override
  Future<void> close() async => closed = true;
}

class FakeSounds extends CallSounds {
  final List<String> calls = [];
  @override
  Future<void> ring() async => calls.add('ring');
  @override
  Future<void> ringback() async => calls.add('ringback');
  @override
  Future<void> stop() async => calls.add('stop');
  @override
  Future<void> inCall(bool on, {String name = ''}) async =>
      calls.add('inCall $on');
}

/// A call log that only keeps entries in memory.
class MemoryLog extends CallLog {
  final List<CallLogEntry> entries = [];
  @override
  Future<void> add(CallLogEntry entry) async => entries.add(entry);
}

class Harness {
  final sent = <Map<String, dynamic>>[];
  final medias = <FakeMedia>[];
  final sounds = FakeSounds();
  final log = MemoryLog();
  List<Map<String, dynamic>>? servers = [
    {
      'urls': ['stun:stun.example.org'],
    },
  ];
  bool online = true;
  int incomingShown = 0;
  late final CallController call;
  FakeMedia? nextMedia;

  Harness() {
    call = CallController(
      createMedia: () {
        final m = nextMedia ?? FakeMedia();
        nextMedia = null;
        medias.add(m);
        return m;
      },
      sounds: sounds,
      log: log,
      send: (e) {
        if (!online) return false;
        sent.add(Map.of(e));
        return true;
      },
      // "Encryption" the test can see through: the peer's ID wraps the text.
      encrypt: (peer, text) async => 'enc($peer):$text',
      decrypt: (peer, content) async {
        final prefix = 'enc(me):';
        return content.startsWith(prefix)
            ? content.substring(prefix.length)
            : null;
      },
      iceServers: () async => servers,
      nameOf: (id) async => 'Name of $id',
      onIncoming: () => incomingShown++,
      connectTimeout: const Duration(milliseconds: 200),
      reconnectTimeout: const Duration(milliseconds: 200),
      endedFor: const Duration(milliseconds: 50),
    );
  }

  FakeMedia get media => medias.last;

  List<String> sentTypes() => sent.map((e) => e['type'] as String).toList();

  Map<String, dynamic> lastOf(String type) =>
      sent.lastWhere((e) => e['type'] == type);

  Future<void> receive(Map<String, dynamic> event) => call.handleEvent(event);

  /// An incoming call from bob with the given ID.
  Future<void> incoming([String id = 'c1']) => receive({
    'type': 'call_offer',
    'call_id': id,
    'sender_id': 'BOB',
    'content': 'enc(me):OFFER-FROM-BOB',
  });
}

Future<void> settle() => Future<void>.delayed(Duration.zero);
