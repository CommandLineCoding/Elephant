import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/core/message_payload.dart';
import 'package:mobile/core/shared_location.dart';
import 'package:mobile/services/location_service.dart';

import 'chat_harness.dart';

const place = SharedLocation(48.858370, 2.294481, accuracy: 18.4);

String locationMessage(SharedLocation l) {
  final (data, text) = l.toPayload();
  return MessagePayload.encode('location', data, text: text);
}

/// Answers the location channel, or fails like the phone does.
void answerLocation({Map<String, dynamic>? with_, String? error}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('elephant/location'), (
        call,
      ) async {
        if (error != null) throw PlatformException(code: error);
        return with_;
      });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(mockPlatformChannels);
  tearDown(() {
    debugUriLauncher = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('elephant/location'),
          null,
        );
  });

  group('the location payload', () {
    test('round-trips, and older apps get coordinates and a map link', () {
      final content = locationMessage(place);
      final read = SharedLocation.fromPayload(
        MessagePayload.split(content).payload,
      )!;
      expect(read.lat, 48.85837);
      expect(read.lon, 2.29448);
      expect(read.accuracy, 18);

      final text = MessagePayload.readable(content);
      expect(text, startsWith('📍 Location: 48.85837, 2.29448\n'));
      expect(
        text,
        contains(
          'https://www.openstreetmap.org/?mlat=48.85837&mlon=2.29448#map=16/48.85837/2.29448',
        ),
      );
    });

    test('the links are built from the numbers', () {
      expect(
        place.geoLink.toString(),
        'geo:48.85837,2.29448?q=48.85837,2.29448',
      );
      expect(place.webLink.host, 'www.openstreetmap.org');
      expect(place.webLink.queryParameters, {
        'mlat': '48.85837',
        'mlon': '2.29448',
      });
    });

    test('accepts whole numbers, and no accuracy', () {
      final p = SharedLocation.fromPayload(
        MessagePayload('location', {'lat': 10, 'lon': -20}),
      )!;
      expect(p.lat, 10);
      expect(p.lon, -20);
      expect(p.accuracy, isNull);
    });

    test('rejects anything that is not a place on Earth', () {
      SharedLocation? read(Map<String, dynamic> data) =>
          SharedLocation.fromPayload(MessagePayload('location', data));
      expect(read({'lat': 91, 'lon': 0}), isNull);
      expect(read({'lat': -90.1, 'lon': 0}), isNull);
      expect(read({'lat': 0, 'lon': 180.5}), isNull);
      expect(read({'lat': 0, 'lon': -181}), isNull);
      expect(read({'lat': '48.8', 'lon': 2.3}), isNull);
      expect(read({'lat': 48.8}), isNull);
      expect(read({'lon': 2.3}), isNull);
      expect(read({'lat': 1e308 * 10, 'lon': 0}), isNull);
      expect(SharedLocation.fromPayload(null), isNull);
      expect(
        SharedLocation.fromPayload(
          MessagePayload('poll', {'lat': 1, 'lon': 1}),
        ),
        isNull,
      );
      expect(read({'lat': 90, 'lon': 180}), isNotNull);
      expect(read({'lat': -90, 'lon': -180}), isNotNull);
    });

    test('NaN is not a place', () {
      expect(
        SharedLocation.fromPayload(
          MessagePayload('location', {'lat': double.nan, 'lon': 0}),
        ),
        isNull,
      );
      expect(
        SharedLocation.fromPayload(
          MessagePayload('location', {'lat': 0, 'lon': double.nan}),
        ),
        isNull,
      );
    });

    test('coordinates are sent to about a metre, no more exactly', () {
      final (data, _) = const SharedLocation(
        48.123456789,
        2.987654321,
        accuracy: 12.6,
      ).toPayload();
      expect(data['lat'], 48.12346);
      expect(data['lon'], 2.98765);
      expect(data['acc'], 13.0);
    });

    test('an odd accuracy is dropped, not the place', () {
      SharedLocation? read(Object? acc) => SharedLocation.fromPayload(
        MessagePayload('location', {'lat': 1, 'lon': 1, 'acc': acc}),
      );
      expect(read(-5)!.accuracy, isNull);
      expect(read('close')!.accuracy, isNull);
      expect(read(12)!.accuracy, 12);
    });
  });

  group('opening a place in maps', () {
    test('uses the maps app when there is one', () async {
      final opened = <Uri>[];
      debugUriLauncher = (uri) async {
        opened.add(uri);
        return true;
      };
      expect(await openInMaps(place), isTrue);
      expect(opened.single.scheme, 'geo');
    });

    test('falls back to OpenStreetMap in a browser', () async {
      final opened = <Uri>[];
      debugUriLauncher = (uri) async {
        opened.add(uri);
        return uri.scheme == 'https';
      };
      expect(await openInMaps(place), isTrue);
      expect(opened.map((u) => u.scheme), ['geo', 'https']);
    });

    test('says so when nothing can open it', () async {
      debugUriLauncher = (uri) async => false;
      expect(await openInMaps(place), isFalse);
    });
  });

  group('finding the phone', () {
    test('reads the location from the phone', () async {
      answerLocation(with_: {'lat': 1.5, 'lon': -2.5, 'accuracy': 12.0});
      final found = await LocationService().current();
      expect(found.problem, isNull);
      expect(found.location!.lat, 1.5);
      expect(found.location!.lon, -2.5);
      expect(found.location!.accuracy, 12.0);
    });

    test('explains why there is none', () async {
      for (final (code, problem) in [
        ('denied', LocationProblem.denied),
        ('disabled', LocationProblem.disabled),
        ('unavailable', LocationProblem.unavailable),
        ('busy', LocationProblem.unavailable),
      ]) {
        answerLocation(error: code);
        final found = await LocationService().current();
        expect(found.location, isNull, reason: code);
        expect(found.problem, problem, reason: code);
      }
    });

    test('a reply with no coordinates is unavailable', () async {
      answerLocation(with_: {'accuracy': 1.0});
      expect(
        (await LocationService().current()).problem,
        LocationProblem.unavailable,
      );
    });

    test('without the Android side it is unavailable too', () async {
      expect(
        (await LocationService().current()).problem,
        LocationProblem.unavailable,
      );
    });
  });

  group('in a chat', () {
    Future<TestChat> attachLocation(WidgetTester tester) async {
      final chat = await showTestChat(tester, messages: []);
      await tester.tap(find.byTooltip('Attach'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Location'));
      await tester.pumpAndSettle();
      return chat;
    }

    testWidgets('asks first, then sends where you are', (tester) async {
      answerLocation(
        with_: {'lat': 48.858370, 'lon': 2.294481, 'accuracy': 18.4},
      );
      final chat = await attachLocation(tester);

      expect(find.text('Share your location?'), findsOneWidget);
      expect(chat.sent, isEmpty);
      await tester.tap(find.text('Share'));
      await tester.pumpAndSettle();

      final sent = chat.sent.single;
      expect(sent.silent, isFalse, reason: 'a location is a message');
      final read = SharedLocation.fromPayload(
        MessagePayload.split(sent.text).payload,
      )!;
      expect(read.lat, 48.85837);
      expect(read.accuracy, 18);
      expect(find.text('Location'), findsOneWidget);
      expect(find.text('48.85837, 2.29448'), findsOneWidget);
      expect(find.text('Within about 18 m'), findsOneWidget);
    });

    testWidgets('sends nothing if you cancel', (tester) async {
      answerLocation(with_: {'lat': 1.0, 'lon': 1.0});
      final chat = await attachLocation(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(chat.sent, isEmpty);
    });

    testWidgets('says what to do when permission is denied', (tester) async {
      answerLocation(error: 'denied');
      final chat = await attachLocation(tester);
      await tester.tap(find.text('Share'));
      await tester.pumpAndSettle();
      expect(chat.sent, isEmpty);
      expect(find.textContaining('Allow location access'), findsOneWidget);
    });

    testWidgets('says to turn location on when it is off', (tester) async {
      answerLocation(error: 'disabled');
      await attachLocation(tester);
      await tester.tap(find.text('Share'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Turn on location'), findsOneWidget);
    });

    testWidgets('a place that arrives is a card that opens in maps', (
      tester,
    ) async {
      final opened = <Uri>[];
      debugUriLauncher = (uri) async {
        opened.add(uri);
        return true;
      };
      await showTestChat(
        tester,
        messages: [testMessage('l1', locationMessage(place))],
      );
      expect(find.text('Location'), findsOneWidget);
      expect(find.textContaining('openstreetmap'), findsNothing);

      await tester.tap(find.text('Open in maps'));
      await tester.pumpAndSettle();
      expect(
        opened.single.toString(),
        'geo:48.85837,2.29448?q=48.85837,2.29448',
      );
    });

    testWidgets('says so when no app can open it', (tester) async {
      debugUriLauncher = (uri) async => false;
      await showTestChat(
        tester,
        messages: [testMessage('l1', locationMessage(place))],
      );
      await tester.tap(find.text('Open in maps'));
      await tester.pumpAndSettle();
      expect(find.text("Couldn't open a maps app"), findsOneWidget);
    });

    testWidgets('a place that makes no sense shows its text instead', (
      tester,
    ) async {
      final bad = MessagePayload.encode('location', {
        'lat': 500,
        'lon': 0,
      }, text: '📍 Location: nowhere');
      await showTestChat(tester, messages: [testMessage('l1', bad)]);
      expect(find.text('📍 Location: nowhere'), findsOneWidget);
      expect(find.text('Open in maps'), findsNothing);
    });
  });
}
