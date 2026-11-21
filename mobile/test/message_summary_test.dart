import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/controllers/chat/chat_meta.dart';
import 'package:mobile/core/message_envelope.dart';
import 'package:mobile/core/message_payload.dart';
import 'package:mobile/core/message_summary.dart';
import 'package:mobile/core/shared_contact.dart';
import 'package:mobile/core/shared_location.dart';
import 'package:mobile/models/message.dart';

import 'chat_harness.dart';

const place = SharedLocation(27.041, 88.2663);
const person = SharedContact(
  id: '123e4567-e89b-12d3-a456-426614174000',
  name: 'Maya Rao',
  username: 'maya.0042',
);

String locationContent() {
  final (data, text) = place.toPayload();
  return MessagePayload.encode('location', data, text: text);
}

String contactContent() {
  final (data, text) = person.toPayload();
  return MessagePayload.encode('contact', data, text: text);
}

String pinContent(String target) {
  final (data, text) = ChatMeta.pinPayload(target, true);
  return MessagePayload.encode('pin', data, text: text);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(mockPlatformChannels);

  group('a short line for a message', () {
    test('a location is a label, not coordinates and a link', () {
      final line = summarizeContent(locationContent());
      expect(line, '📍 Location');
      expect(line, isNot(contains('openstreetmap')));
    });

    test('a contact is its name', () {
      expect(summarizeContent(contactContent()), '👤 Contact: Maya Rao');
    });

    test('plain text and mentions read as before', () {
      expect(summarizeContent('see you at 5'), 'see you at 5');
      expect(
        summarizeContent('hi @[Maya](123e4567-e89b-12d3-a456-426614174000)'),
        'hi @[Maya](123e4567-e89b-12d3-a456-426614174000)',
      );
    });

    test('a location payload that is not a real place keeps its text', () {
      final content = MessagePayload.encode('location', {
        'lat': 200,
        'lon': 5,
      }, text: 'look here');
      expect(summarizeContent(content), 'look here');
    });

    test('the message and the chat list agree', () {
      final message = testMessage('m1', locationContent());
      expect(message.summary, '📍 Location');
      expect(message.plainText, startsWith('📍 Location: 27.04100'));
      expect(MessageEnvelope.preview(locationContent()), '📍 Location');
      expect(
        MessageEnvelope.preview(MessageEnvelope.plain(contactContent())),
        '👤 Contact: Maya Rao',
      );
    });

    test('a message that is not a place or person is unchanged', () {
      final Message m = testMessage('m2', 'bring snacks');
      expect(m.summary, 'bring snacks');
    });
  });

  group('the pinned bar', () {
    testWidgets('shows a label for a pinned location', (tester) async {
      await showTestChat(
        tester,
        messages: [
          testMessage('loc', locationContent()),
          testMessage('p1', pinContent('loc')),
        ],
      );
      expect(find.text('Pinned message'), findsOneWidget);
      expect(find.text('📍 Location'), findsOneWidget);
      expect(find.textContaining('openstreetmap'), findsNothing);
    });

    testWidgets('shows the name of a pinned contact', (tester) async {
      await showTestChat(
        tester,
        messages: [
          testMessage('c1', contactContent()),
          testMessage('p1', pinContent('c1')),
        ],
      );
      expect(find.text('👤 Contact: Maya Rao'), findsOneWidget);
    });
  });
}
