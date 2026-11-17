import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/controllers/call/call_controller.dart';
import 'package:mobile/services/calls/call_log.dart';
import 'package:mobile/services/calls/call_media.dart';

import 'call_fakes.dart';

void main() {
  group('calling out', () {
    test('sends an encrypted offer, then the candidates', () async {
      final h = Harness();
      expect(await h.call.call('BOB', 'Bob'), isNull);

      expect(h.call.phase, CallPhase.calling);
      expect(h.call.peerId, 'bob');
      final offer = h.lastOf('call_offer');
      expect(offer['receiver_id'], 'bob');
      expect(offer['content'], 'enc(bob):OFFER');
      expect(offer['call_id'], h.call.callId);

      await settle();
      // The candidate found while the offer was being made waited for it.
      expect(h.sentTypes(), ['call_offer', 'call_ice']);
      expect(h.lastOf('call_ice')['content'], 'enc(bob):cand-early');
      expect(h.sounds.calls, contains('inCall true'));
    });

    test('rings, gets answered and connects', () async {
      final h = Harness();
      await h.call.call('bob', 'Bob');
      final id = h.call.callId!;

      await h.receive({'type': 'call_ring', 'call_id': id});
      expect(h.call.phase, CallPhase.ringing);
      expect(h.sounds.calls.last, 'ringback');

      // A candidate that arrives before the answer waits for it.
      await h.receive({
        'type': 'call_ice',
        'call_id': id,
        'content': 'enc(me):bob-cand-1',
      });
      expect(h.media.added, isEmpty);

      await h.receive({
        'type': 'call_answer',
        'call_id': id,
        'content': 'enc(me):ANSWER',
      });
      expect(h.media.log, contains('accept ANSWER'));
      expect(h.media.added, ['bob-cand-1']);
      expect(h.call.phase, CallPhase.connecting);

      await h.receive({
        'type': 'call_ice',
        'call_id': id,
        'content': 'enc(me):bob-cand-2',
      });
      expect(h.media.added, ['bob-cand-1', 'bob-cand-2']);

      h.media.onState!(MediaState.connected);
      expect(h.call.phase, CallPhase.connected);
      expect(h.call.connectedAt, isNotNull);
    });

    test('hanging up a connected call logs its length', () async {
      final h = Harness();
      await h.call.call('bob', 'Bob');
      final id = h.call.callId!;
      await h.receive({
        'type': 'call_answer',
        'call_id': id,
        'content': 'enc(me):ANSWER',
      });
      h.media.onState!(MediaState.connected);

      h.call.hangUp();
      expect(h.lastOf('call_hangup'), {
        'type': 'call_hangup',
        'call_id': id,
        'reason': 'ended',
      });
      expect(h.call.phase, CallPhase.ended);
      expect(h.media.closed, isTrue);
      expect(h.sounds.calls, contains('inCall false'));
      expect(h.log.entries.single.outcome, CallOutcome.answered);
      expect(h.log.entries.single.outgoing, isTrue);
      expect(h.log.entries.single.chatId, 'bob');

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(h.call.phase, CallPhase.idle);
    });

    test('cancelling before an answer', () async {
      final h = Harness();
      await h.call.call('bob', 'Bob');
      h.call.hangUp();
      expect(h.lastOf('call_hangup')['reason'], 'ended');
      expect(h.log.entries.single.outcome, CallOutcome.cancelled);
    });

    for (final (reason, text, outcome) in [
      ('declined', 'Declined', CallOutcome.declined),
      ('timeout', 'No answer', CallOutcome.noAnswer),
      ('unavailable', 'Unavailable', CallOutcome.unavailable),
    ]) {
      test('the other side ending it: $reason', () async {
        final h = Harness();
        await h.call.call('bob', 'Bob');
        await h.receive({
          'type': 'call_hangup',
          'call_id': h.call.callId,
          'reason': reason,
        });
        expect(h.call.phase, CallPhase.ended);
        expect(h.call.endedText, text);
        expect(h.log.entries.single.outcome, outcome);
        // Nobody to tell: the hang-up came from the other side.
        expect(h.sentTypes(), isNot(contains('call_hangup')));
      });
    }

    test('busy', () async {
      final h = Harness();
      await h.call.call('bob', 'Bob');
      await h.receive({'type': 'call_busy', 'call_id': h.call.callId});
      expect(h.call.endedText, 'Busy');
      expect(h.log.entries.single.outcome, CallOutcome.busy);
    });

    test('events for another call are ignored', () async {
      final h = Harness();
      await h.call.call('bob', 'Bob');
      await h.receive({
        'type': 'call_hangup',
        'call_id': 'someone-elses',
        'reason': 'declined',
      });
      await h.receive({
        'type': 'call_answer',
        'call_id': 'someone-elses',
        'content': 'enc(me):X',
      });
      expect(h.call.phase, CallPhase.calling);
      expect(h.media.log, isNot(contains('accept X')));
    });

    test('an answer that is not properly encrypted ends the call', () async {
      final h = Harness();
      await h.call.call('bob', 'Bob');
      await h.receive({
        'type': 'call_answer',
        'call_id': h.call.callId,
        'content': 'PLAIN-SDP-FROM-THE-SERVER',
      });
      expect(h.media.log, isNot(contains('accept PLAIN-SDP-FROM-THE-SERVER')));
      expect(h.call.phase, CallPhase.ended);
      expect(h.lastOf('call_hangup')['reason'], 'ended');
    });

    test('a server without calls', () async {
      final h = Harness()..servers = null;
      final error = await h.call.call('bob', 'Bob');
      expect(error, contains("doesn't support calls"));
      expect(h.call.phase, CallPhase.idle);
      expect(h.sent, isEmpty);
      expect(h.log.entries, isEmpty);
    });

    test('no microphone', () async {
      final h = Harness()
        ..nextMedia = (FakeMedia()
          ..openError = Exception('Permission denied: NotAllowedError'));
      final error = await h.call.call('bob', 'Bob');
      expect(error, contains('microphone'));
      expect(h.call.phase, CallPhase.idle);
      expect(h.sent, isEmpty);
    });

    test('offline', () async {
      final h = Harness()..online = false;
      expect(await h.call.call('bob', 'Bob'), "You're offline");
      expect(h.call.phase, CallPhase.idle);
      expect(h.media.closed, isTrue);
    });

    test('hanging up while the microphone opens still closes it', () async {
      final gate = Completer<void>();
      final h = Harness()..nextMedia = (FakeMedia()..openGate = gate);
      final calling = h.call.call('bob', 'Bob');
      await settle();
      h.call.hangUp();
      gate.complete();
      await calling;
      expect(h.media.closed, isTrue);
      expect(h.sentTypes(), isNot(contains('call_offer')));
    });

    test("can't start a second call", () async {
      final h = Harness();
      await h.call.call('bob', 'Bob');
      expect(await h.call.call('carol', 'Carol'), "You're already in a call");
      expect(h.call.peerId, 'bob');
    });

    test('an answered call that never connects gives up', () async {
      final h = Harness();
      await h.call.call('bob', 'Bob');
      await h.receive({
        'type': 'call_answer',
        'call_id': h.call.callId,
        'content': 'enc(me):ANSWER',
      });
      await Future<void>.delayed(const Duration(milliseconds: 260));
      expect(h.call.endedText, "Couldn't connect");
      expect(h.log.entries.single.outcome, CallOutcome.failed);
      expect(h.lastOf('call_hangup')['reason'], 'ended');
    });
  });

  group('being called', () {
    test('rings and shows the call screen', () async {
      final h = Harness();
      await h.incoming();
      expect(h.call.phase, CallPhase.incoming);
      expect(h.call.peerId, 'bob');
      expect(h.call.peerName, 'Name of bob');
      expect(h.call.outgoing, isFalse);
      expect(h.sentTypes(), ['call_ring']);
      expect(h.sounds.calls, ['ring']);
      expect(h.incomingShown, 1);
      // No microphone until the call is answered.
      expect(h.medias, isEmpty);
    });

    test(
      'accepting answers, then adds the candidates that came early',
      () async {
        final h = Harness();
        await h.incoming();
        await h.receive({
          'type': 'call_ice',
          'call_id': 'c1',
          'content': 'enc(me):early',
        });

        await h.call.accept();
        expect(h.media.log, ['open 1', 'answer to OFFER-FROM-BOB']);
        expect(h.media.added, ['early']);
        expect(h.lastOf('call_answer')['content'], 'enc(bob):ANSWER');
        expect(h.call.phase, CallPhase.connecting);
        expect(h.sounds.calls, containsAllInOrder(['ring', 'stop']));

        h.media.onCandidate!('mine');
        await settle();
        expect(h.lastOf('call_ice')['content'], 'enc(bob):mine');

        h.media.onState!(MediaState.connected);
        expect(h.call.phase, CallPhase.connected);
      },
    );

    test('declining', () async {
      final h = Harness();
      await h.incoming();
      h.call.decline();
      expect(h.lastOf('call_hangup')['reason'], 'declined');
      expect(h.sounds.calls.last, 'inCall false');
      expect(h.log.entries.single.outcome, CallOutcome.declined);
      expect(h.log.entries.single.outgoing, isFalse);
    });

    test('the caller giving up is a missed call', () async {
      final h = Harness();
      await h.incoming();
      await h.receive({
        'type': 'call_hangup',
        'call_id': 'c1',
        'reason': 'ended',
      });
      expect(h.call.endedText, 'Missed call');
      expect(h.log.entries.single.isMissed, isTrue);
    });

    test('an offer that is not properly encrypted is refused', () async {
      final h = Harness();
      await h.receive({
        'type': 'call_offer',
        'call_id': 'c9',
        'sender_id': 'mallory',
        'content': '{"sdp":"v=0 server-made","type":"offer"}',
      });
      expect(h.call.phase, CallPhase.idle);
      expect(h.incomingShown, 0);
      expect(h.sounds.calls, isEmpty);
      expect(h.lastOf('call_hangup'), {
        'type': 'call_hangup',
        'call_id': 'c9',
        'reason': 'ended',
      });
    });

    test('a second offer during a call is ignored', () async {
      final h = Harness();
      await h.incoming('c1');
      await h.receive({
        'type': 'call_offer',
        'call_id': 'c2',
        'sender_id': 'carol',
        'content': 'enc(me):OFFER',
      });
      expect(h.call.callId, 'c1');
      expect(h.incomingShown, 1);
    });
  });

  group('during a call', () {
    Future<Harness> connected() async {
      final h = Harness();
      await h.incoming();
      await h.call.accept();
      h.media.onState!(MediaState.connected);
      return h;
    }

    test('mute and speaker', () async {
      final h = await connected();
      h.call.toggleMute();
      expect(h.media.muted, isTrue);
      await h.call.toggleSpeaker();
      expect(h.media.speaker, isTrue);
      expect(h.call.muted && h.call.speaker, isTrue);
    });

    test('a brief drop recovers', () async {
      final h = await connected();
      h.media.onState!(MediaState.disconnected);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      h.media.onState!(MediaState.connected);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(h.call.phase, CallPhase.connected);
    });

    test('a drop that lasts ends the call', () async {
      final h = await connected();
      h.media.onState!(MediaState.disconnected);
      await Future<void>.delayed(const Duration(milliseconds: 260));
      expect(h.call.endedText, 'Connection lost');
      expect(h.log.entries.single.outcome, CallOutcome.answered);
    });

    test('the other side hanging up', () async {
      final h = await connected();
      await h.receive({
        'type': 'call_hangup',
        'call_id': 'c1',
        'reason': 'disconnected',
      });
      expect(h.call.endedText, 'Connection lost');
      expect(h.media.closed, isTrue);
    });
  });

  test('call log labels', () {
    CallLogEntry entry(CallOutcome o, {bool out = false, int secs = 0}) =>
        CallLogEntry(
          id: 'x',
          chatId: 'bob',
          outgoing: out,
          outcome: o,
          startedAt: DateTime(2026),
          duration: Duration(seconds: secs),
        );
    expect(entry(CallOutcome.answered, secs: 192).label, 'Voice call · 3:12');
    expect(
      entry(CallOutcome.answered, secs: 3725).label,
      'Voice call · 1:02:05',
    );
    expect(entry(CallOutcome.missed).label, 'Missed voice call');
    expect(entry(CallOutcome.declined).label, 'Declined voice call');
    expect(entry(CallOutcome.declined, out: true).label, 'Voice call declined');
    expect(
      entry(CallOutcome.noAnswer, out: true).label,
      'Voice call · No answer',
    );
  });
}
