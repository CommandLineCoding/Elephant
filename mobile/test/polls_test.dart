import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/controllers/chat/chat_meta.dart';
import 'package:mobile/core/message_payload.dart';
import 'package:mobile/core/poll.dart';
import 'package:mobile/pages/chat/create_poll_page.dart';
import 'package:mobile/services/blocked_users.dart';

import 'chat_harness.dart';

const poll = PollData('Which day?', ['Friday', 'Saturday', 'Sunday']);

String pollMessage(PollData p) {
  final (data, text) = p.toPayload();
  return MessagePayload.encode('poll', data, text: text);
}

String vote(String pollId, Set<int> options) {
  final (data, text) = votePayload(pollId, options);
  return MessagePayload.encode('vote', data, text: text);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(mockPlatformChannels);
  tearDown(BlockedUsers.instance.clear);

  group('the poll payload', () {
    test('round-trips, and older apps get a readable version', () {
      const multi = PollData('Toppings?', ['Cheese', 'Olives'], multi: true);
      final content = pollMessage(multi);
      final read = PollData.fromPayload(MessagePayload.split(content).payload)!;
      expect(read.question, 'Toppings?');
      expect(read.options, ['Cheese', 'Olives']);
      expect(read.multi, isTrue);
      expect(
        MessagePayload.readable(content),
        '📊 Poll: Toppings?\n▫️ Cheese\n▫️ Olives',
      );
    });

    test('unusable polls are refused', () {
      MessagePayload p(Map<String, dynamic> data) =>
          MessagePayload('poll', data);
      expect(PollData.fromPayload(null), isNull);
      expect(PollData.fromPayload(MessagePayload('reaction', {})), isNull);
      expect(
        PollData.fromPayload(
          p({
            'q': 'x',
            'opts': ['a'],
          }),
        ),
        isNull,
      );
      expect(
        PollData.fromPayload(
          p({
            'q': '',
            'opts': ['a', 'b'],
          }),
        ),
        isNull,
      );
      expect(
        PollData.fromPayload(
          p({
            'q': 'x',
            'opts': ['a', 5],
          }),
        ),
        isNull,
      );
      expect(
        PollData.fromPayload(
          p({
            'q': 'x',
            'opts': ['a', ' '],
          }),
        ),
        isNull,
      );
      expect(
        PollData.fromPayload(
          p({'q': 'x', 'opts': List.generate(11, (i) => 'o$i')}),
        ),
        isNull,
      );
      expect(
        PollData.fromPayload(
          p({
            'opts': ['a', 'b'],
          }),
        ),
        isNull,
      );
    });

    test('says what is wrong with a draft', () {
      expect(PollData.problemWith('', ['a', 'b']), 'Ask a question.');
      expect(
        PollData.problemWith('q', ['a', ' ']),
        'Add at least two options.',
      );
      expect(
        PollData.problemWith('q', ['a', 'a']),
        'Each option has to be different.',
      );
      expect(PollData.problemWith('q', ['a', 'b', '']), isNull);
    });
  });

  group('counting votes', () {
    test('adds up, with the latest vote of each person', () {
      final meta = ChatMeta.from([
        testMessage('p', pollMessage(poll), sender: 'me'),
        testMessage('v1', vote('p', {0}), sender: 'ava'),
        testMessage('v2', vote('p', {1}), sender: 'ben'),
        testMessage('v3', vote('p', {1}), sender: 'ava'),
        testMessage('v4', vote('p', {1}), sender: 'me'),
      ], 'me');
      final tally = meta.tallyOf('p', poll);

      expect(tally.voters, 3);
      expect(tally.countFor(0), 0);
      expect(tally.countFor(1), 3);
      expect(tally.votersByOption[1], ['ben', 'ava', 'me']);
      expect(tally.picksOf('me'), {1});
      expect(tally.shareOf(1), 1.0);
      expect(tally.shareOf(2), 0);
    });

    test('an empty vote takes it back', () {
      final meta = ChatMeta.from([
        testMessage('v1', vote('p', {0}), sender: 'ava'),
        testMessage('v2', vote('p', {}), sender: 'ava'),
      ], 'me');
      final tally = meta.tallyOf('p', poll);
      expect(tally.voters, 0);
      expect(tally.shareOf(0), 0, reason: 'no division by zero');
    });

    test('a single-choice poll keeps the first pick, multi keeps all', () {
      final messages = [
        testMessage('v1', vote('p', {2, 0}), sender: 'ava'),
      ];
      final single = ChatMeta.from(messages, 'me').tallyOf('p', poll);
      expect(single.picksOf('ava'), {0});

      const multi = PollData('?', ['a', 'b', 'c'], multi: true);
      final both = ChatMeta.from(messages, 'me').tallyOf('p', multi);
      expect(both.picksOf('ava'), {0, 2});
    });

    test('picks outside the poll are dropped', () {
      final meta = ChatMeta.from([
        testMessage('v1', vote('p', {7}), sender: 'ava'),
        testMessage('v2', vote('p', {1, 9}), sender: 'ben'),
      ], 'me');
      final tally = meta.tallyOf('p', poll);
      expect(tally.voters, 1);
      expect(tally.picksOf('ben'), {1});
    });

    test('bad votes are ignored', () {
      MessagePayload.encode('vote', {}, text: 'x');
      final meta = ChatMeta.from([
        testMessage(
          'a',
          MessagePayload.encode('vote', {
            'opts': [0],
          }, text: 'x'),
        ),
        testMessage(
          'b',
          MessagePayload.encode('vote', {
            'poll': 'p',
            'opts': 'zero',
          }, text: 'x'),
        ),
        testMessage(
          'c',
          MessagePayload.encode('vote', {
            'poll': 'p',
            'opts': [0, 'x'],
          }, text: 'x'),
        ),
        testMessage(
          'd',
          MessagePayload.encode('vote', {
            'poll': 'p',
            'opts': [99],
          }, text: 'x'),
        ),
        testMessage(
          'e',
          MessagePayload.encode('vote', {
            'poll': 'p',
            'opts': List.filled(11, 0),
          }, text: 'x'),
        ),
      ], 'me');
      expect(meta.tallyOf('p', poll).voters, 0);
    });

    test('an invalid re-vote leaves the earlier vote alone', () {
      final meta = ChatMeta.from([
        testMessage('v1', vote('p', {1}), sender: 'ava'),
        testMessage(
          'v2',
          MessagePayload.encode('vote', {
            'poll': 'p',
            'opts': [0, 99],
          }, text: 'x'),
          sender: 'ava',
        ),
      ], 'me');
      expect(meta.tallyOf('p', poll).picksOf('ava'), {1});
    });

    test('a vote is attributed to who sent it', () {
      final spoof = MessagePayload.encode('vote', {
        'poll': 'p',
        'opts': [0],
        'voter': 'me',
      }, text: 'x');
      final meta = ChatMeta.from([
        testMessage('v', spoof, sender: 'ava'),
      ], 'me');
      expect(meta.tallyOf('p', poll).picksOf('me'), isEmpty);
      expect(meta.tallyOf('p', poll).picksOf('ava'), {0});
    });
  });

  group('on the chat page', () {
    testWidgets('a poll shows its options and votes', (tester) async {
      await showTestChat(
        tester,
        messages: [
          testMessage('p', pollMessage(poll)),
          testMessage('v1', vote('p', {1}), sender: 'ben'),
          testMessage('v2', vote('p', {1}), sender: 'ava'),
          testMessage('v3', vote('p', {0}), sender: 'cy'),
        ],
      );
      expect(find.text('Which day?'), findsOneWidget);
      expect(find.text('Select one'), findsOneWidget);
      for (final option in poll.options) {
        expect(find.text(option), findsOneWidget);
      }
      expect(find.text('3 votes'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      // Neither the votes nor the poll's fallback text are messages.
      expect(find.textContaining('Voted in a poll'), findsNothing);
      expect(find.textContaining('▫️'), findsNothing);
    });

    testWidgets('tapping an option votes, and tapping it again takes it back', (
      tester,
    ) async {
      final chat = await showTestChat(
        tester,
        messages: [testMessage('p', pollMessage(poll))],
      );
      await tester.tap(find.text('Saturday'));
      await tester.pumpAndSettle();

      final sent = chat.sent.single;
      expect(sent.silent, isTrue);
      final payload = MessagePayload.split(sent.text).payload!;
      expect(payload.kind, 'vote');
      expect(payload.field<String>('poll'), 'p');
      expect(payload.field<List>('opts'), [1]);
      expect(find.text('1 vote'), findsOneWidget);

      await tester.tap(find.text('Saturday'));
      await tester.pumpAndSettle();
      expect(
        MessagePayload.split(chat.sent.last.text).payload!.field<List>('opts'),
        isEmpty,
      );
      expect(find.text('No votes yet'), findsOneWidget);
    });

    testWidgets('in a single-choice poll a new pick replaces the old one', (
      tester,
    ) async {
      final chat = await showTestChat(
        tester,
        messages: [
          testMessage('p', pollMessage(poll)),
          testMessage('v', vote('p', {0}), sender: 'me'),
        ],
      );
      await tester.tap(find.text('Sunday'));
      await tester.pumpAndSettle();
      expect(
        MessagePayload.split(
          chat.sent.single.text,
        ).payload!.field<List>('opts'),
        [2],
      );
    });

    testWidgets('a multiple-choice poll adds and removes picks', (
      tester,
    ) async {
      const multi = PollData('Toppings?', [
        'Cheese',
        'Olives',
        'Ham',
      ], multi: true);
      final chat = await showTestChat(
        tester,
        messages: [
          testMessage('p', pollMessage(multi)),
          testMessage('v', vote('p', {0}), sender: 'me'),
        ],
      );
      expect(find.text('Select one or more'), findsOneWidget);
      await tester.tap(find.text('Ham'));
      await tester.pumpAndSettle();
      expect(
        MessagePayload.split(chat.sent.last.text).payload!.field<List>('opts'),
        [0, 2],
      );

      await tester.tap(find.text('Cheese'));
      await tester.pumpAndSettle();
      expect(
        MessagePayload.split(chat.sent.last.text).payload!.field<List>('opts'),
        [2],
      );
    });

    testWidgets('View votes lists who voted for what', (tester) async {
      await showTestChat(
        tester,
        messages: [
          testMessage('p', pollMessage(poll)),
          testMessage('v1', vote('p', {1}), sender: 'u2'),
          testMessage('v2', vote('p', {1}), sender: 'me'),
        ],
      );
      await tester.tap(find.text('View votes'));
      await tester.pumpAndSettle();
      final sheet = find.byType(BottomSheet);
      expect(
        find.descendant(of: sheet, matching: find.text('You')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sheet, matching: find.text('Bob')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sheet, matching: find.text('No votes')),
        findsNWidgets(2),
      );
    });

    testWidgets("can't vote in a chat you blocked", (tester) async {
      BlockedUsers.instance.debugSetUsers(const [
        BlockedUser(id: 'u2', username: 'bob.1234', displayName: 'Bob'),
      ]);
      final chat = await showTestChat(
        tester,
        messages: [testMessage('p', pollMessage(poll))],
      );
      await tester.tap(find.text('Friday'));
      await tester.pumpAndSettle();
      expect(chat.sent, isEmpty);
    });

    testWidgets('a poll that can not be read shows its text instead', (
      tester,
    ) async {
      final broken = MessagePayload.encode('poll', {
        'q': 'x',
      }, text: '📊 Poll: x');
      await showTestChat(tester, messages: [testMessage('p', broken)]);
      expect(find.text('📊 Poll: x'), findsOneWidget);
    });
  });

  group('creating a poll', () {
    Future<void> openCreator(WidgetTester tester) async {
      final chat = await showTestChat(tester, messages: []);
      await tester.tap(find.byTooltip('Attach'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Poll'));
      await tester.pumpAndSettle();
      expect(find.byType(CreatePollPage), findsOneWidget);
      addTearDown(() => chat.sent.clear());
    }

    testWidgets('writes a poll and sends it', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final chat = await showTestChat(tester, messages: []);
      await tester.tap(find.byTooltip('Attach'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Poll'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Ask a question'),
        'Lunch?',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Option 1'),
        'Pizza',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Option 2'),
        'Sushi',
      );
      await tester.tap(find.text('Add option'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Option 3'),
        'Salad',
      );
      await tester.tap(find.text('Allow multiple answers'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();

      expect(find.byType(CreatePollPage), findsNothing);
      final payload = MessagePayload.split(chat.sent.single.text).payload!;
      expect(payload.kind, 'poll');
      expect(chat.sent.single.silent, isFalse, reason: 'a poll is a message');
      final sentPoll = PollData.fromPayload(payload)!;
      expect(sentPoll.question, 'Lunch?');
      expect(sentPoll.options, ['Pizza', 'Sushi', 'Salad']);
      expect(sentPoll.multi, isTrue);
      expect(find.text('Lunch?'), findsOneWidget);
    });

    testWidgets('will not send an incomplete poll', (tester) async {
      await openCreator(tester);
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(find.text('Ask a question.'), findsOneWidget);
      expect(find.byType(CreatePollPage), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'Ask a question'),
        'Q',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Option 1'),
        'Only one',
      );
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(find.text('Add at least two options.'), findsOneWidget);
    });

    testWidgets('options can be added up to ten and removed down to two', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(800, 3200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await openCreator(tester);
      for (var i = 0; i < 8; i++) {
        await tester.tap(find.text('Add option'));
        await tester.pumpAndSettle();
      }
      expect(find.widgetWithText(TextField, 'Option 10'), findsOneWidget);
      expect(find.text('Add option'), findsNothing);

      for (var i = 0; i < 8; i++) {
        await tester.tap(find.byTooltip('Remove option 1').first);
        await tester.pumpAndSettle();
      }
      expect(find.byTooltip('Remove option 1'), findsNothing);
      expect(find.widgetWithText(TextField, 'Option 2'), findsOneWidget);
    });
  });
}
