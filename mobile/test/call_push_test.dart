import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/services/api_services.dart';
import 'package:mobile/services/push/push_notifier.dart';

void main() {
  group('pending call', () {
    test('is read from the response', () {
      final call = PendingCall.fromResponse({
        'success': true,
        'data': {
          'call_id': 'c1',
          'caller_id': 'u-ava',
          'caller_display_name': 'Ava',
        },
      });
      expect(call?.id, 'c1');
      expect(call?.callerId, 'u-ava');
      expect(call?.callerName, 'Ava');
    });

    test('nothing ringing', () {
      expect(PendingCall.fromResponse({'success': true}), isNull);
      expect(PendingCall.fromResponse(null), isNull);
      expect(
        PendingCall.fromResponse({
          'data': {'call_id': '', 'caller_id': 'x'},
        }),
        isNull,
      );
    });
  });

  group('incoming call notification', () {
    test('names the caller when names are shown', () {
      final text = callNotificationText('Ava', showName: true);
      expect(text.title, 'Ava');
      expect(text.body, 'Incoming voice call · Tap to answer');
    });

    test("doesn't say who is calling when names are hidden", () {
      final text = callNotificationText('Ava', showName: false);
      expect(text.title, 'Incoming voice call');
      expect(text.body, isNot(contains('Ava')));
    });

    test('an unknown caller', () {
      expect(
        callNotificationText('', showName: true).title,
        'Incoming voice call',
      );
    });
  });
}
