import '../../controllers/call/call_controller.dart';
import '../../controllers/chat/inbox_controller.dart';
import '../../core/message_envelope.dart';
import '../api_services.dart';
import '../signal_service.dart';
import '../ws_service.dart';
import 'call_log.dart';
import 'call_media.dart';
import 'call_sounds.dart';

/// The app's [CallController], on WebRTC, the WebSocket and Signal.
CallController createCallController(InboxController inbox) {
  return CallController(
    createMedia: WebRtcCallMedia.new,
    sounds: CallSounds(),
    log: CallLog.instance,
    send: WebSocketService().emit,
    encrypt: _encrypt,
    decrypt: decryptCallSignal,
    iceServers: ApiService().iceServers,
    nameOf: (id) => _nameOf(inbox, id),
  );
}

Future<String> _encrypt(String peerId, String text) async {
  if (!await SignalService().establishSessionIfNeeded(peerId)) {
    throw StateError("Couldn't reach this contact's encryption keys");
  }
  return SignalService().encryptDirect(peerId, text);
}

/// Decrypts call setup from [peerId]. Only a Signal message is accepted:
/// anything sent in the clear could have come from the server, which must
/// not be able to set up (and so listen in on) a call.
Future<String?> decryptCallSignal(String peerId, String content) async {
  final envelope = MessageEnvelope.tryParse(content);
  if (envelope == null || envelope.isPlaintext) return null;
  final text = await SignalService().decodeIncoming(peerId, content);
  return MessageEnvelope.isUnreadable(text) ? null : text;
}

Future<String> _nameOf(InboxController inbox, String userId) async {
  for (final item in inbox.inbox) {
    if (!item.isGroup && item.id.toLowerCase() == userId.toLowerCase()) {
      return item.title;
    }
  }
  try {
    final response = await ApiService().getUser(userId);
    final data = ApiService.dataMap(response.data);
    final name =
        data['display_name']?.toString() ?? data['username']?.toString();
    if (name != null && name.isNotEmpty) return name;
  } catch (_) {}
  return 'Someone';
}
