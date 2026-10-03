import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:mobile/core/constants.dart';
import 'package:mobile/core/message_envelope.dart';
import 'package:mobile/services/ws_service.dart';

/// The server closes sockets on frames over 4096 bytes. Check that the
/// plaintext budget for direct messages survives Signal encryption, base64
/// and double JSON encoding, using the largest (PreKey) message type.
void main() {
  test('max-size direct message fits in one WebSocket frame', () async {
    final aliceStore = InMemorySignalProtocolStore(
      generateIdentityKeyPair(),
      generateRegistrationId(false),
    );
    final bobIdentity = generateIdentityKeyPair();
    final bobStore = InMemorySignalProtocolStore(
      bobIdentity,
      generateRegistrationId(false),
    );

    final bobPreKey = generatePreKeys(0, 1).first;
    final bobSigned = generateSignedPreKey(bobIdentity, 0);
    await bobStore.storePreKey(bobPreKey.id, bobPreKey);
    await bobStore.storeSignedPreKey(bobSigned.id, bobSigned);

    final bobAddress = SignalProtocolAddress(
      'bob-0000-0000-0000-000000000000',
      1,
    );
    await SessionBuilder.fromSignalStore(
      aliceStore,
      bobAddress,
    ).processPreKeyBundle(
      PreKeyBundle(
        await bobStore.getLocalRegistrationId(),
        1,
        bobPreKey.id,
        bobPreKey.getKeyPair().publicKey,
        bobSigned.id,
        bobSigned.getKeyPair().publicKey,
        bobSigned.signature,
        bobIdentity.getPublicKey(),
      ),
    );

    // Worst realistic case: multi-byte characters filling the byte budget.
    final plaintext = '🐘' * (ServerLimits.maxDirectMessageBytes ~/ 4);
    expect(
      utf8.encode(plaintext).length,
      lessThanOrEqualTo(ServerLimits.maxDirectMessageBytes),
    );

    final cipher = SessionCipher.fromStore(aliceStore, bobAddress);
    final encrypted = await cipher.encrypt(
      Uint8List.fromList(utf8.encode(plaintext)),
    );
    expect(encrypted.getType(), CiphertextMessage.prekeyType);

    final frame = WebSocketService.chatFrame(
      messageId: '00000000-0000-0000-0000-000000000000',
      receiverId: '11111111-1111-1111-1111-111111111111',
      content: MessageEnvelope(
        encrypted.getType(),
        base64Encode(encrypted.serialize()),
      ).encode(),
      replyToMessageId: '22222222-2222-2222-2222-222222222222',
    );

    final size = WebSocketService.frameSize(frame);
    // ignore: avoid_print
    print('Largest direct-message frame: $size bytes');
    expect(size, lessThanOrEqualTo(ServerLimits.maxWsFrameBytes));
  });
}
