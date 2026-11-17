import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Where the audio connection stands.
enum MediaState { connecting, connected, disconnected, failed }

/// The audio side of a call. [CallController] drives it; tests use a fake.
abstract class CallMedia {
  /// Opens the microphone and prepares a connection. Throws if the
  /// microphone can't be used (e.g. permission denied).
  Future<void> open({
    required List<Map<String, dynamic>> iceServers,
    required void Function(String candidate) onCandidate,
    required void Function(MediaState state) onState,
  });

  /// The SDP offer, as JSON.
  Future<String> createOffer();

  /// Takes the caller's offer and returns the SDP answer, as JSON.
  Future<String> answer(String offer);

  Future<void> acceptAnswer(String answer);

  /// Adds one of the other phone's ICE candidates, as JSON.
  Future<void> addCandidate(String candidate);

  void setMuted(bool muted);

  Future<void> setSpeaker(bool on);

  Future<void> close();
}

/// [CallMedia] on WebRTC. The other person's audio plays as soon as it
/// arrives; the microphone track is the only thing sent.
class WebRtcCallMedia implements CallMedia {
  RTCPeerConnection? _pc;
  MediaStream? _mic;

  @override
  Future<void> open({
    required List<Map<String, dynamic>> iceServers,
    required void Function(String candidate) onCandidate,
    required void Function(MediaState state) onState,
  }) async {
    _mic = await navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
      'video': false,
    });
    final pc = await createPeerConnection({
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
    });
    _pc = pc;
    for (final track in _mic!.getAudioTracks()) {
      await pc.addTrack(track, _mic!);
    }
    pc.onIceCandidate = (c) {
      if (c.candidate != null && c.candidate!.isNotEmpty) {
        onCandidate(jsonEncode(c.toMap()));
      }
    };
    pc.onConnectionState = (state) {
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          onState(MediaState.connected);
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          onState(MediaState.disconnected);
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          onState(MediaState.failed);
        case RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
          onState(MediaState.connecting);
        default:
          break;
      }
    };
    // A voice call starts on the earpiece, like a phone call.
    await Helper.setSpeakerphoneOn(false);
  }

  @override
  Future<String> createOffer() async {
    final offer = await _pc!.createOffer({'offerToReceiveAudio': true});
    await _pc!.setLocalDescription(offer);
    return jsonEncode(offer.toMap());
  }

  @override
  Future<String> answer(String offer) async {
    final o = jsonDecode(offer) as Map<String, dynamic>;
    await _pc!.setRemoteDescription(RTCSessionDescription(o['sdp'], o['type']));
    final answer = await _pc!.createAnswer();
    await _pc!.setLocalDescription(answer);
    return jsonEncode(answer.toMap());
  }

  @override
  Future<void> acceptAnswer(String answer) async {
    final a = jsonDecode(answer) as Map<String, dynamic>;
    await _pc!.setRemoteDescription(RTCSessionDescription(a['sdp'], a['type']));
  }

  @override
  Future<void> addCandidate(String candidate) async {
    final c = jsonDecode(candidate) as Map<String, dynamic>;
    await _pc?.addCandidate(
      RTCIceCandidate(c['candidate'], c['sdpMid'], c['sdpMLineIndex']),
    );
  }

  @override
  void setMuted(bool muted) {
    for (final track in _mic?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = !muted;
    }
  }

  @override
  Future<void> setSpeaker(bool on) => Helper.setSpeakerphoneOn(on);

  @override
  Future<void> close() async {
    try {
      for (final track in _mic?.getTracks() ?? const <MediaStreamTrack>[]) {
        await track.stop();
      }
      await _mic?.dispose();
      await _pc?.close();
      await _pc?.dispose();
    } catch (e) {
      debugPrint('Call media close: $e');
    }
    _mic = null;
    _pc = null;
  }
}
